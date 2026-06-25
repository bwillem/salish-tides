import SwiftUI

/// Current speed at the crosshair, in its own compact readout card — the
/// primary at-a-glance datum. Sits below the tide/phase card (`PhaseIndicatorView`).
/// Em dash when the crosshair is on land / off coverage.
struct CurrentSpeedView: View {
    @Environment(MapViewModel.self) private var vm
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if vm.currentSelection != nil {
            // Icon centered to the value; value + unit baseline-aligned ("0.3 kn")
            // and scale down together rather than wrap.
            HStack(alignment: .center, spacing: Spacing.xs) {
                directionIcon
                    .font(.stReadoutUnit)
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
                        .foregroundStyle(Color.inkSecondary)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .floatingCard()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(crosshairSpeedLabel)
        }
    }

    /// An arrow tilted to the current's flow direction at the crosshair
    /// (compass bearing; `arrow.up` = north, rotated clockwise). Falls back to
    /// the `scope` reticle when there's no current to point.
    @ViewBuilder
    private var directionIcon: some View {
        if let direction = vm.crosshairDirection {
            Image(systemName: "arrow.up")
                .rotationEffect(.degrees(direction))
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "scope")
                .foregroundStyle(Color.inkSecondary)
        }
    }

    /// Speed value without the unit (the unit rides separately, smaller).
    private func speedValue(_ knots: Double) -> String {
        settings.speedUnit.value(fromKnots: knots)
            .formatted(.number.precision(.fractionLength(1)))
    }

    private var crosshairSpeedLabel: String {
        guard let speed = vm.crosshairSpeed else { return "No current at crosshair." }
        if let direction = vm.crosshairDirection {
            return "\(settings.formatSpeed(knots: speed)) flowing \(compassPoint(direction)) at crosshair."
        }
        return "\(settings.formatSpeed(knots: speed)) at crosshair."
    }

    /// Eight-point compass word for a bearing (0 = north, clockwise).
    private func compassPoint(_ degrees: Double) -> String {
        let points = ["north", "north-east", "east", "south-east",
                      "south", "south-west", "west", "north-west"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5)
            .truncatingRemainder(dividingBy: 360)) / 45) % 8
        return points[index]
    }
}
