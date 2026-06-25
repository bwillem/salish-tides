import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings
    @State private var offsetHours: Int = 0
    @State private var sessionAnchor: Date = .now

    // Reflects the live scrub position (displayDate), not just the committed
    // offset, so the dot/pill respond as the user drags.
    private var isNow: Bool {
        abs(vm.displayDate.timeIntervalSince(sessionAnchor)) < 60
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {

            // ── Time readout + contextual "Now" pill ─────────────────────────
            // The readout is purely informational (centred, neutral, with a live
            // dot at the present). When scrubbed, an amber "Now" pill fades in at
            // the right — the unambiguous tap target to return. Amber lives on the
            // action, not on the time itself. (Phase/tendency is omitted here —
            // it already lives in the phase-indicator card.)
            ZStack {
                readout
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
                    vm.scrub(to: sessionAnchor.addingTimeInterval(offset * 3600))
                },
                onCommit: { applyOffset() }
            )
            .frame(height: 36)
        }
        .onAppear { jumpToNow() }
    }

    // MARK: - Readout (information only)

    @ViewBuilder private var readout: some View {
        HStack(spacing: 5) {
            if isNow {
                Circle()
                    .fill(Color.oceanLight)
                    .frame(width: 6, height: 6)
            }
            Text(settings.formatTimelineDate(vm.displayDate))
                .font(.stClock)
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
                .background(Color.oceanMid, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Return to now")
        .accessibilityHint("Returns the timeline to the current time")
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

    // The tape steps in whole hours, so "now" is the top of the current Salish
    // hour — the actual hourly chart being shown — not the live wall-clock
    // minute. Flooring in Salish time keeps it aligned with the tape ticks.
    private static func topOfCurrentHour() -> Date {
        let cal = Calendar.salish
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: .now)) ?? .now
    }
}
