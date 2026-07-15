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
                              events: vm.tideEvents,
                              live: vm.liveTideSeries)
                    .frame(height: 108)
                    .accessibilityElement()
                    .accessibilityLabel(tideChartLabel)

                // Station provenance + tide phase on one wrapping caption line,
                // e.g. "Georgina Point · Small Ebb". The phase keeps its
                // flood/ebb colour as the only emphasis — the old large phase
                // title + arrow was more weight than this secondary readout
                // needs. Datum and the "Live" flag are omitted (jargon /
                // ambiguous; the chart's a11y label and the Online-mode badge in
                // ContentView cover them).
                provenanceLine(sel)
                    .font(.stCaption)
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel(phaseAccessibilityLabel(sel))
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

    /// "Station · Phase" as one Text, the phase tinted flood/ebb — e.g.
    /// "Georgina Point · Small Ebb". Falls back to just the phase when no
    /// station resolved.
    private func provenanceLine(_ sel: ChartSelection) -> Text {
        let phase = Text(phaseText(sel)).foregroundStyle(tendencyColor(sel.tendency))
        guard let station = vm.tideStation else { return phase }
        return Text(station.name.titleCasedStation) + Text("  ·  ") + phase
    }

    private func phaseAccessibilityLabel(_ sel: ChartSelection) -> String {
        guard let station = vm.tideStation else { return "\(phaseText(sel)) tide." }
        return "\(station.name.titleCasedStation), \(phaseText(sel)) tide."
    }

    /// Display name for the tide phase, e.g. "Small Flood".
    private func phaseText(_ sel: ChartSelection) -> String {
        sel.phase.replacingOccurrences(of: "_", with: " ").capitalized
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

#Preview("Tide card") {
    // Stub VM/settings so the card renders standalone in the canvas — no DB or
    // network. Tweak the fields below (station name casing, phase, events) and
    // the canvas updates live. "BEDWELL HARBOUR" is deliberately ALL CAPS to
    // exercise titleCasedStation.
    let vm = MapViewModel()
    let base = Date(timeIntervalSince1970: 1_752_534_000)
    vm.currentDate = base
    vm.displayDate = base
    vm.tideStation = TideStation(id: "CHS:07330", name: "BEDWELL HARBOUR",
                                 lat: 48.75, lon: -123.23, datum: "CD", source: "CHS")
    vm.tideEvents = [
        TideEvent(time: base.addingTimeInterval(-6 * 3600), height: 0.9, isHigh: false),
        TideEvent(time: base.addingTimeInterval(-1 * 3600), height: 3.4, isHigh: true),
        TideEvent(time: base.addingTimeInterval(4 * 3600),  height: 2.6, isHigh: false),
        TideEvent(time: base.addingTimeInterval(9 * 3600),  height: 3.2, isHigh: true),
    ]
    vm.currentSelections = [ChartSelection(volume: 1, chart: 3, phase: "small_ebb", tendency: .ebb)]

    return PhaseIndicatorView()
        .environment(vm)
        .environment(AppSettings(defaults: UserDefaults(suiteName: "preview.phasecard")!))
        .padding(40)
}
