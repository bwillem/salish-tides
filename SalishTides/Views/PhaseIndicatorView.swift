import SwiftUI

struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm

    var body: some View {
        if let sel = vm.currentSelection {
            VStack(spacing: 0) {

                // ── Tide height chart ────────────────────────────────────────
                TideChartView(currentDate: vm.currentDate)
                    .frame(height: 108)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)

                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 0.5)

                // ── Phase info row ───────────────────────────────────────────
                HStack(spacing: Spacing.sm) {
                    Image(systemName: tendencyIcon(sel.tendency))
                        .foregroundStyle(tendencyColor(sel.tendency))
                        .imageScale(.medium)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(sel.phase.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.stHeadline)

                        if let speed = vm.crosshairSpeed {
                            Text(String(format: "%.1f kn ✛", speed))
                                .font(.stMono)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
            .frame(width: 248)
        }
    }

    private func tendencyIcon(_ tendency: Tendency) -> String {
        tendency == .flood ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private func tendencyColor(_ tendency: Tendency) -> Color {
        tendency == .flood ? .tideFlood : .tideEbb
    }
}
