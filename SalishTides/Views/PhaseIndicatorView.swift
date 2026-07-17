import SwiftUI

/// Tide chart + its phase state, as one floating card. The current speed at the
/// crosshair lives in its own card — see `CurrentSpeedView`.
struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if vm.tideStation != nil {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TideChartView(currentDate: vm.displayDate,
                              events: vm.tideEvents,
                              live: vm.liveTideSeries)
                    .frame(height: 108)
                    .accessibilityElement()
                    .accessibilityLabel(tideChartLabel)

                // Station and tide phase, each on its own line, left-aligned and
                // inset to the chart's plot edge (past the y-axis labels) so they
                // line up under the curve. A plain up/down arrow marks flood/ebb
                // (no colour); datum and the "Live" flag are omitted (jargon /
                // ambiguous — the chart's a11y label and the Online-mode badge in
                // ContentView cover them).
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let station = vm.tideStation {
                        Text(station.name.stationDisplayName)
                    }
                    if let phase = vm.currentPhase {
                        Text("\(phase.tendency == .flood ? "↑" : "↓") \(phaseText(phase))")
                    }
                }
                .font(.stCaption)
                .foregroundStyle(Color.inkSecondary)
                // Both lines stay at caption size (no per-line minimumScaleFactor,
                // which would shrink a long station name out of step with the
                // short phase line); an over-long name truncates instead.
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, TideChartView.plotLeftInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(vm.currentPhase.map(phaseAccessibilityLabel) ?? "")
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
        return String(format: "Tide %.1f %@ at %@, above %@.", height, unit, station.name.stationDisplayName, datum)
    }

    // Just the phase — the station name is already announced by the chart's
    // own a11y label (tideChartLabel), so repeating it here would double up.
    private func phaseAccessibilityLabel(_ phase: CurrentPhase) -> String {
        "\(phaseText(phase)) tide."
    }

    /// Display name for the tide phase — "Flood"/"Ebb", strength-prefixed
    /// ("Large Flood") if a strength ever ships.
    private func phaseText(_ phase: CurrentPhase) -> String {
        let base = phase.tendency == .flood ? "Flood" : "Ebb"
        switch phase.strength {
        case .small: return "Small \(base)"
        case .medium: return "Medium \(base)"
        case .large: return "Large \(base)"
        case nil: return base
        }
    }
}

private extension String {
    /// Display form of a raw tide-station name. Two normalisations:
    /// 1. Keep only the first comma-separated component — some stations bundle a
    ///    location hierarchy ("Hanbury Point, Mosquito Pass, San Juan I."); the
    ///    first part is the specific spot and all we want to show.
    /// 2. Case: sources arrive inconsistently, so Title-Case the ALL-CAPS ones;
    ///    names that already contain a lowercase letter are assumed correct and
    ///    left untouched (so `.capitalized` doesn't mangle "McNeill"/"Fisher's").
    ///    Short (≤2-letter) tokens keep their caps, so directionals/abbreviations
    ///    survive — "NW ROCK" → "NW Rock", not "Nw Rock".
    var stationDisplayName: String {
        let first = split(separator: ",", maxSplits: 1).first.map(String.init) ?? self
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(where: \.isLowercase) else { return trimmed }
        return trimmed
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                guard word.filter(\.isLetter).count > 2 else { return String(word) }
                let lower = word.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")
    }
}

#Preview("Tide card") {
    // Stub VM/settings so the card renders standalone in the canvas — no DB or
    // network. Tweak the fields below (station name casing, phase, events) and
    // the canvas updates live. Name is deliberately ALL CAPS + multi-part to
    // exercise stationDisplayName (first segment, Title-Cased).
    let vm = MapViewModel()
    let base = Date(timeIntervalSince1970: 1_752_534_000)
    vm.currentDate = base
    vm.displayDate = base
    vm.tideStation = TideStation(id: "NOAA:9449880", name: "HANBURY POINT, MOSQUITO PASS, SAN JUAN I.",
                                 lat: 48.6, lon: -123.15, datum: "MLLW", source: "NOAA")
    vm.tideEvents = [
        TideEvent(time: base.addingTimeInterval(-6 * 3600), height: 0.9, isHigh: false),
        TideEvent(time: base.addingTimeInterval(-1 * 3600), height: 3.4, isHigh: true),
        TideEvent(time: base.addingTimeInterval(4 * 3600),  height: 2.6, isHigh: false),
        TideEvent(time: base.addingTimeInterval(9 * 3600),  height: 3.2, isHigh: true),
    ]
    vm.currentPhase = CurrentPhase(tendency: .ebb, strength: nil, basis: .currentCorrelation)

    return PhaseIndicatorView()
        .environment(vm)
        .environment(AppSettings(defaults: UserDefaults(suiteName: "preview.phasecard") ?? .standard))
        .padding(40)
}
