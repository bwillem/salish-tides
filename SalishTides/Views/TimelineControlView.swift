import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @State private var offsetHours: Int = 0
    @State private var sessionAnchor: Date = .now

    private var isNow: Bool { offsetHours == 0 }

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
                sessionAnchor: sessionAnchor
            ) {
                applyOffset()
            }
            .frame(height: 36)
        }
        .onAppear { sessionAnchor = .now }
    }

    // MARK: - Readout (information only)

    @ViewBuilder private var readout: some View {
        HStack(spacing: 5) {
            if isNow {
                Circle()
                    .fill(Color.oceanLight)
                    .frame(width: 6, height: 6)
            }
            Text(vm.currentDate,
                 format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.stClock)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeLabel)
    }

    private var timeLabel: String {
        let time = vm.currentDate.formatted(date: .abbreviated, time: .shortened)
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
        sessionAnchor = .now
        offsetHours = 0
        Task { await vm.setTime(sessionAnchor) }
    }

    private func applyOffset() {
        let date = sessionAnchor.addingTimeInterval(Double(offsetHours) * 3600)
        Task { await vm.setTime(date) }
    }
}
