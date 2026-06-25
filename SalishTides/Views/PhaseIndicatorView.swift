import SwiftUI

/// Tide chart + its phase state, as one floating card. The current speed at the
/// crosshair lives in its own card — see `CurrentSpeedView`.
struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let sel = vm.currentSelection {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TideChartView(currentDate: vm.displayDate,
                              events: vm.tideEvents)
                    .frame(height: 108)
                    .accessibilityElement()
                    .accessibilityLabel(tideChartLabel)

                // Provenance: which station the curve is from + its datum.
                // Sits directly under the chart it labels.
                if let station = vm.tideStation {
                    Text("\(station.name) · \(station.datum)")
                        .font(.stCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                // Phase state.
                HStack(spacing: Spacing.xs) {
                    Image(systemName: tendencyIcon(sel.tendency))
                        .font(.stPhase.weight(.semibold))
                        .foregroundStyle(tendencyColor(sel.tendency))
                    Text(phaseText(sel))
                        .font(.stPhase)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(phaseText(sel)) tide.")
            }
            .padding(Spacing.md)
            .frame(width: 248)
            .floatingCard()
        }
    }

    private var tideChartLabel: String {
        guard let station = vm.tideStation,
              let h = TideCurve.height(at: vm.displayDate, events: vm.tideEvents) else {
            return "Tide chart. Data unavailable."
        }
        let datum = station.datum == "MLLW" ? "mean lower low water" : "chart datum"
        let height = settings.heightUnit.value(fromMetres: h)
        let unit = settings.heightUnit.label.lowercased()
        return String(format: "Tide %.1f %@ at %@, above %@.", height, unit, station.name, datum)
    }

    /// Display name for the tide phase, e.g. "Small Flood".
    private func phaseText(_ sel: ChartSelection) -> String {
        sel.phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func tendencyIcon(_ tendency: Tendency) -> String {
        tendency == .flood ? "arrow.up" : "arrow.down"
    }

    private func tendencyColor(_ tendency: Tendency) -> Color {
        tendency == .flood ? .tideFlood : .tideEbb
    }
}
