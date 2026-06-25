import SwiftUI

struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let sel = vm.currentSelection {
            // Two groups separated by spacing alone (no divider): the tide
            // chart + its phase state, then the current-speed hero.
            VStack(alignment: .leading, spacing: Spacing.lg) {

                // ── Tide group: chart + its phase state (conceptually one) ───
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TideChartView(currentDate: vm.displayDate,
                                  station: vm.tideStation,
                                  events: vm.tideEvents)
                        .frame(height: 108)
                        .accessibilityElement()
                        .accessibilityLabel(tideChartLabel)

                    // Phase state labels the chart it sits under.
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: tendencyIcon(sel.tendency))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tendencyColor(sel.tendency))
                        Text(phaseText(sel))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(phaseText(sel)) tide.")
                }

                // ── Current speed at the crosshair (hero) ────────────────────
                // Em dash when the crosshair is on land / off coverage.
                // Center the scope icon to the value; the value + unit stay
                // baseline-aligned to each other ("0.3 kn").
                HStack(alignment: .center, spacing: Spacing.xs) {
                    Image(systemName: "scope")
                        .font(.stReadoutUnit)
                        .foregroundStyle(.secondary)
                    if let speed = vm.crosshairSpeed {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                            Text(speedValue(speed))
                                .font(.stReadout)
                            Text(settings.speedUnit.abbreviation)
                                .font(.stReadoutUnit)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("—")
                            .font(.stReadout)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(crosshairSpeedLabel)
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

    /// Speed value without the unit (the unit rides separately, smaller).
    private func speedValue(_ knots: Double) -> String {
        settings.speedUnit.value(fromKnots: knots)
            .formatted(.number.precision(.fractionLength(1)))
    }

    /// Display name for the tide phase, e.g. "Small Flood".
    private func phaseText(_ sel: ChartSelection) -> String {
        sel.phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// VoiceOver label for the hero readout (the crosshair current speed).
    private var crosshairSpeedLabel: String {
        if let speed = vm.crosshairSpeed {
            return "\(settings.formatSpeed(knots: speed)) at crosshair."
        }
        return "No current at crosshair."
    }

    private func tendencyIcon(_ tendency: Tendency) -> String {
        tendency == .flood ? "arrow.up" : "arrow.down"
    }

    private func tendencyColor(_ tendency: Tendency) -> Color {
        tendency == .flood ? .tideFlood : .tideEbb
    }
}
