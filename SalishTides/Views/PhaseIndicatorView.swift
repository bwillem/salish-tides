import SwiftUI

/// Tide chart + its phase state, as one floating card. The current speed at the
/// crosshair lives in its own card — see `CurrentSpeedView`.
struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let sel = vm.currentSelection {
            VStack(alignment: .leading, spacing: Spacing.md) {

                // Chart + its station label, tightly grouped.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TideChartView(currentDate: vm.displayDate,
                                  events: vm.tideEvents,
                                  live: vm.liveTideSeries)
                        .frame(height: 108)
                        .accessibilityElement()
                        .accessibilityLabel(tideChartLabel)

                    // Provenance: which station the curve is from + its datum,
                    // and whether the drawn curve itself is live model data.
                    if let station = vm.tideStation {
                        Text("\(station.name) · \(station.datum)\(isLiveTide ? " · Live" : "")")
                            .font(.stCaption)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                // Phase state — separated from the chart group by more space.
                HStack(spacing: Spacing.xs) {
                    Image(systemName: tendencyIcon(sel.tendency))
                        .font(.stPhase.weight(.semibold))
                        .foregroundStyle(tendencyColor(sel.tendency))
                    Text(phaseText(sel))
                        .font(.stPhase)
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(phaseText(sel)) tide.")
            }
            .padding(Spacing.md)
            .frame(width: 248)
            .floatingCard()
        }
    }

    /// Whether the drawn tide curve is live model data at the cursor.
    private var isLiveTide: Bool {
        vm.liveTideSeries?.covers(vm.displayDate) == true
    }

    private var tideChartLabel: String {
        let predicted = TideCurve.height(at: vm.displayDate, events: vm.tideEvents)
        guard let station = vm.tideStation,
              let h = vm.liveTideSeries?.blendedHeight(at: vm.displayDate, fallback: predicted)
                ?? predicted else {
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
