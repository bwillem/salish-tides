import SwiftUI

struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm

    var body: some View {
        if let sel = vm.currentSelection {
            HStack(spacing: 8) {
                Image(systemName: tendencyIcon(sel.tendency))
                    .foregroundStyle(tendencyColor(sel.tendency))
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sel.phase.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.subheadline.bold())
                    Text("Chart \(sel.chart) of 43")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private func tendencyIcon(_ tendency: Tendency) -> String {
        tendency == .flood ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private func tendencyColor(_ tendency: Tendency) -> Color {
        tendency == .flood ? .blue : .orange
    }
}
