import SwiftUI

struct TimelineControlView: View {
    @Environment(MapViewModel.self) private var vm
    @State private var offsetHours: Int = 0
    @State private var sessionAnchor: Date = .now

    var body: some View {
        VStack(spacing: Spacing.sm) {

            // ── Header row: Now button · date/phase ──────────────────────────
            HStack(alignment: .center) {
                Button("Now") { jumpToNow() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(offsetHours == 0 ? nil : Color.tideEbb)

                Spacer()

                VStack(spacing: 2) {
                    Text(vm.currentDate,
                         format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.stClock)

                    if let sel = vm.currentSelection {
                        Text(sel.phase
                            .replacingOccurrences(of: "_", with: " ")
                            .capitalized)
                            .font(.stCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Invisible balance weight matching the Now button width
                Color.clear.frame(width: 54, height: 1)
            }

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
