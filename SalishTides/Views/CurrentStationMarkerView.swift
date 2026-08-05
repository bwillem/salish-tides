import SwiftUI

/// A CHS current-station marker (Dodd Narrows, Seymour Narrows, Active Pass, ...)
/// — a small glass badge over the map, positioned by the `MapLibreView`
/// coordinator via `CurrentStationMarkerPresenter`. Same real Liquid Glass as the
/// tide-station marker (the shared `.floatingCard()` surface), so it samples the
/// map behind it instead of compositing flat like a MapLibre annotation would.
///
/// The glyph is an arrow rotated to the flow bearing and tinted by speed (calm →
/// very strong), or a neutral dot at slack. A tap reveals a name + speed pill;
/// the full slack/max card is layered on in Phase 3b.
struct CurrentStationMarkerView: View {
    let marker: CurrentStationMarkerPresenter.Marker
    let isSelected: Bool
    let onTap: () -> Void

    private static let badgeSize: CGFloat = 24
    private static let hitSize: CGFloat = 44   // HIG minimum touch target
    /// Below this the flow has no meaningful direction — show a slack dot.
    private static let slackKn = 0.3

    var body: some View {
        badge
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Circle())
            .onTapGesture(perform: onTap)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current station: \(marker.name)")
            .accessibilityValue(speedText + ", " + (marker.isFlood ? "flooding" : "ebbing"))
            .accessibilityAddTraits(.isButton)
    }

    private var badge: some View {
        Group {
            if marker.speedKn < Self.slackKn {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "arrow.up")
                    .font(.stStationGlyph)
                    .foregroundStyle(Self.rampColor(marker.speedKn))
                    .rotationEffect(.degrees(marker.bearingDeg))
            }
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .floatingCard(cornerRadius: Self.badgeSize / 2)
        // Selected badge gets a tint ring so it's clear which card is open.
        .overlay(
            Circle().strokeBorder(Color.brandAccent, lineWidth: isSelected ? 2 : 0)
                .frame(width: Self.badgeSize, height: Self.badgeSize)
        )
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var speedText: String {
        String(format: "%.1f kn", marker.speedKn)
    }

    /// SwiftUI mirror of `UIColor.currentSpeedRamp` buckets (calm → very strong).
    private static func rampColor(_ kn: Double) -> Color {
        switch kn {
        case ..<0.5:  .blue
        case ..<1.5:  .teal
        case ..<3.0:  .yellow
        case ..<4.5:  .orange
        default:      .red
        }
    }
}
