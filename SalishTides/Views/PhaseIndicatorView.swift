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

                    // Provenance: which station the tide curve is from. The datum
                    // (e.g. "CD"/"MLLW") is omitted — jargon that means nothing to
                    // a user; the a11y label below still states it in words. The
                    // "Live" flag is dropped too: "live what?" reads as ambiguous,
                    // and the bottom-right Online-mode badge already signals it.
                    if let station = vm.tideStation {
                        Text(station.name.titleCasedStation)
                            .font(.stCaption)
                            .foregroundStyle(Color.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, alignment: .center)
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
                // Currents-source provenance (Online mode / Offline model) lives
                // in its own bottom-right glass pill now — see SourceBadge in
                // ContentView — so it isn't crowded into this card.
            }
            .padding(Spacing.md)
            .frame(width: 248)
            .floatingCard()
        }
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
        return String(format: "Tide %.1f %@ at %@, above %@.", height, unit, station.name.titleCasedStation, datum)
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

private extension String {
    /// Tide-station names arrive inconsistently cased — some sources give Title
    /// Case, others ALL CAPS. Normalise only the all-caps ones to Title Case;
    /// names that already contain a lowercase letter are assumed correct and
    /// left untouched (so we don't `.capitalized`-mangle "McNeill" or "Fisher's").
    var titleCasedStation: String {
        guard !contains(where: \.isLowercase) else { return self }
        return lowercased()
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
