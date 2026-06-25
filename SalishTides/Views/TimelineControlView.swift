import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @State private var offsetHours: Int = 0
    @State private var sessionAnchor: Date = .now

    private var isNow: Bool { offsetHours == 0 }

    // "+3h" / "−2h" — uses a typographic minus, only shown when scrubbed.
    private var offsetLabel: String {
        "\(offsetHours > 0 ? "+" : "−")\(abs(offsetHours))h"
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {

            // ── Time readout — doubles as the "return to now" control ────────
            // Centred. At the present it shows a calm live dot; when scrubbed it
            // turns amber (matching the tape cursor), shows the offset + a reset
            // glyph, and the whole readout becomes tappable to jump back to now.
            Button {
                guard !isNow else { return }
                jumpToNow()
            } label: {
                readout
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: isNow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isNow ? "Current time" : "Return to now")
            .accessibilityValue(spokenValue)
            .accessibilityHint(isNow ? "" : "Returns the timeline to the current time")
            .accessibilityAddTraits(isNow ? [] : .isButton)

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

    // MARK: - Readout

    @ViewBuilder private var readout: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                if isNow {
                    Circle()
                        .fill(Color.oceanLight)
                        .frame(width: 6, height: 6)
                }
                Text(vm.currentDate,
                     format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.stClock)
                if !isNow {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(isNow ? Color.primary : Color.tideEbb)

            HStack(spacing: 6) {
                if let sel = vm.currentSelection {
                    Text(phaseText(sel))
                        .font(.stCaption)
                        .foregroundStyle(isNow ? Color.secondary : Color.tideEbb)
                }
                if !isNow {
                    Text(offsetLabel)
                        .font(.stMono)
                        .foregroundStyle(Color.tideEbb)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func phaseText(_ sel: ChartSelection) -> String {
        sel.phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var spokenValue: String {
        var s = vm.currentDate.formatted(date: .abbreviated, time: .shortened)
        if let sel = vm.currentSelection { s += ", \(phaseText(sel))" }
        if !isNow {
            s += ", \(abs(offsetHours)) hours \(offsetHours > 0 ? "ahead of" : "before") now"
        }
        return s
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
