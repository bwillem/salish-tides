import SwiftUI

struct PhaseIndicatorView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let sel = vm.currentSelection {
            VStack(spacing: 0) {

                // ── Tide height chart ────────────────────────────────────────
                TideChartView(currentDate: vm.displayDate,
                              station: vm.tideStation,
                              events: vm.tideEvents)
                    .frame(height: 108)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xs)
                    .accessibilityElement()
                    .accessibilityLabel(tideChartLabel)

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

                        // Em dash when the crosshair is on land / off coverage —
                        // there's no current speed to report there.
                        HStack(spacing: Spacing.xxs) {
                            Image(systemName: "scope")
                            if let speed = vm.crosshairSpeed {
                                Text(settings.formatSpeed(knots: speed))
                            } else {
                                Text("—")
                            }
                        }
                        .font(.stMono)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(phaseRowLabel(sel))
            }
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

    private func phaseRowLabel(_ sel: ChartSelection) -> String {
        let phase = sel.phase.replacingOccurrences(of: "_", with: " ").lowercased()
        var label = "\(phase) tide."
        if let speed = vm.crosshairSpeed {
            label += " \(settings.formatSpeed(knots: speed)) at crosshair."
        } else {
            label += " No current at crosshair."
        }
        return label
    }

    private func tendencyIcon(_ tendency: Tendency) -> String {
        tendency == .flood ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private func tendencyColor(_ tendency: Tendency) -> Color {
        tendency == .flood ? .tideFlood : .tideEbb
    }
}
