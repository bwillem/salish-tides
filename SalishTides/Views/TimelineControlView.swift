import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @Environment(CrosshairPresenter.self) private var crosshair
    @Environment(\.scenePhase) private var scenePhase
    @State private var offsetHours: Int = 0
    @State private var sessionAnchor: Date = .now
    // True between the first scrub tick of a drag and its commit — gates
    // re-anchoring, which must never move the tape's base under a gesture.
    @State private var isScrubbing = false
    // Drives the date-picker sheet; seeded from the current display date each
    // time it opens so the calendar lands on the day being viewed.
    @State private var showingDatePicker = false
    @State private var pickerDate: Date = .now

    // Reflects the live scrub position (displayDate), not just the committed
    // offset, so the dot/pill respond as the user drags.
    private var isNow: Bool {
        abs(vm.displayDate.timeIntervalSince(sessionAnchor)) < 60
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {

            // ── Time readout + contextual "Now" pill ─────────────────────────
            // The readout is purely informational (centred, neutral, with a live
            // dot at the present). When scrubbed, an amber "Now" pill fades in at
            // the right — the unambiguous tap target to return. Amber lives on the
            // action, not on the time itself. (Phase/tendency is omitted here —
            // it already lives in the phase-indicator card.)
            ZStack {
                Button(action: presentDatePicker) {
                    readout
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens a date picker to jump to any date")
                .popover(isPresented: $showingDatePicker) { datePickerPopover }
                HStack {
                    Spacer()
                    if !isNow {
                        nowPill
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isNow)

            // ── Time tape slider ─────────────────────────────────────────────
            TapeSliderView(
                offsetHours: $offsetHours,
                sessionAnchor: sessionAnchor,
                onScrub: { offset in
                    isScrubbing = true
                    crosshair.interactionBegan()
                    vm.scrub(to: sessionAnchor.addingTimeInterval(offset * 3600))
                },
                onCommit: {
                    isScrubbing = false
                    crosshair.interactionEnded()
                    applyOffset()
                }
            )
            .frame(height: 36)
        }
        .onAppear { jumpToNow() }
        // "Now" moves: without re-anchoring, an app left open (or foregrounded
        // hours later) keeps showing the launch hour with the live dot lit —
        // stale data presented as current. Poll for the hour rolling over, and
        // check immediately on foregrounding.
        .onChange(of: scenePhase) {
            if scenePhase == .active { reanchorIfHourChanged() }
        }
        .task {
            // try-await so cancellation exits at the sleep — a swallowed
            // CancellationError would run one reanchor against a torn-down
            // view before the loop condition could notice.
            do {
                while true {
                    try await Task.sleep(for: .seconds(30))
                    reanchorIfHourChanged()
                }
            } catch {}
        }
    }

    // MARK: - Readout (information only)

    @ViewBuilder private var readout: some View {
        HStack(spacing: 5) {
            if isNow {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
            }
            Text(settings.formatTimelineDate(vm.displayDate))
                .font(.stClock)
            // Affordance that the date opens a picker; muted so it reads as a
            // hint, not a control competing with the time text.
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeLabel)
    }

    private var timeLabel: String {
        let time = settings.formatTimelineDate(vm.displayDate)
        return isNow ? "Now, \(time)" : time
    }

    // MARK: - Now pill (the return-to-now control)

    private var nowPill: some View {
        Button(action: jumpToNow) {
            Text("Now")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
                .background(.tint, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to now")
        .accessibilityHint("Returns the timeline to the current time")
    }

    // MARK: - Date picker

    // Graphical (calendar) picker in a popover anchored to the date readout —
    // the standard iOS pattern for a compact date selector. On iPad it appears
    // beside the readout; on iPhone SwiftUI adapts it to a sheet. Date only; the
    // tape still owns the hour within the chosen day. Picking a day applies it
    // and dismisses (tapping outside dismisses without changing the date), so no
    // Cancel/Done chrome is needed — matching Calendar/Reminders.
    private var datePickerPopover: some View {
        DatePicker(
            "Date",
            selection: $pickerDate,
            displayedComponents: [.date]
        )
        .datePickerStyle(.graphical)
        .frame(width: 320)
        .padding(Spacing.sm)
        .onChange(of: pickerDate) {
            jumpToDate(pickerDate)
            showingDatePicker = false
        }
    }

    private func presentDatePicker() {
        pickerDate = vm.displayDate
        showingDatePicker = true
    }

    // MARK: - Actions

    private func jumpToNow() {
        sessionAnchor = Self.topOfCurrentHour()
        offsetHours = 0
        Task { await vm.setTime(sessionAnchor) }
    }

    private func applyOffset() {
        let date = sessionAnchor.addingTimeInterval(Double(offsetHours) * 3600)
        Task { await vm.setTime(date) }
    }

    // Re-anchor the tape onto an arbitrary day chosen from the picker, keeping
    // the currently displayed hour so only the calendar day moves. Resets the
    // offset to zero so the tape recentres on the new anchor.
    private func jumpToDate(_ date: Date) {
        let cal = Calendar.salish
        let hour = cal.component(.hour, from: vm.displayDate)
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        guard let anchored = cal.date(from: comps) else { return }
        sessionAnchor = anchored
        offsetHours = 0
        Task { await vm.setTime(anchored) }
    }

    // Keep sessionAnchor tracking the real current hour. Sitting at "now"
    // follows the clock (data advances to the new hour); scrubbed away, only
    // the tape's Now marker moves — the user's chosen time stays put by
    // compensating the offset, so nothing reloads.
    private func reanchorIfHourChanged() {
        // Never under an active drag: the gesture's translation is relative
        // to the current anchor/offset, so moving them mid-gesture teleports
        // the tape and commits a time unrelated to the finger. The next tick
        // catches up after the commit.
        guard !isScrubbing else { return }
        let top = Self.topOfCurrentHour()
        guard top != sessionAnchor else { return }
        // Branch on the committed offset, not displayDate proximity — the
        // readout's isNow can be transiently true as a scrub passes the tick.
        if offsetHours == 0 {
            jumpToNow()
        } else {
            let delta = Int((top.timeIntervalSince(sessionAnchor) / 3600).rounded())
            let shifted = offsetHours - delta
            // Out of the tape's range (parked at the -48 h edge as hours roll
            // by): leave everything alone rather than clamp — clamping would
            // silently change the displayed hour under a reading user, once
            // per hour. The marker re-syncs on their next interaction.
            guard abs(shifted) <= TapeSliderView.maxHours else { return }
            sessionAnchor = top
            offsetHours = shifted
        }
    }

    // The tape steps in whole hours, so "now" is the top of the current Salish
    // hour — the actual hourly chart being shown — not the live wall-clock
    // minute. Flooring in Salish time keeps it aligned with the tape ticks.
    private static func topOfCurrentHour() -> Date {
        let cal = Calendar.salish
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: .now)) ?? .now
    }
}
