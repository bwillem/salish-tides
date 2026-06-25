import SwiftUI

/// Current speed at the crosshair, in its own compact readout card — the
/// primary at-a-glance datum. Sits below the tide/phase card (`PhaseIndicatorView`).
/// Em dash when the crosshair is on land / off coverage.
struct CurrentSpeedView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if vm.currentSelection != nil {
            // Scope icon centered to the value; value + unit baseline-aligned
            // ("0.3 kn") and scale down together rather than wrap.
            HStack(alignment: .center, spacing: Spacing.xs) {
                Image(systemName: "scope")
                    .font(.stReadoutUnit)
                    .foregroundStyle(Color.inkSecondary)
                if let speed = vm.crosshairSpeed {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                        Text(speedValue(speed))
                            .font(.stReadout)
                        Text(settings.speedUnit.abbreviation)
                            .font(.stReadoutUnit)
                            .foregroundStyle(Color.inkSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                } else {
                    Text("—")
                        .font(.stReadout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .floatingCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(crosshairSpeedLabel)
        }
    }

    /// Speed value without the unit (the unit rides separately, smaller).
    private func speedValue(_ knots: Double) -> String {
        settings.speedUnit.value(fromKnots: knots)
            .formatted(.number.precision(.fractionLength(1)))
    }

    private var crosshairSpeedLabel: String {
        if let speed = vm.crosshairSpeed {
            return "\(settings.formatSpeed(knots: speed)) at crosshair."
        }
        return "No current at crosshair."
    }
}
