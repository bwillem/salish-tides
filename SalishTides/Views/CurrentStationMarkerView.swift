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

    @State private var tapped = false
    @State private var pillHeight: CGFloat = 0

    private static let badgeSize: CGFloat = 24
    private static let hitSize: CGFloat = 44   // HIG minimum touch target
    /// Below this the flow has no meaningful direction — show a slack dot.
    private static let slackKn = 0.3

    var body: some View {
        ZStack {
            badge
            if tapped {
                pill
                    .background(pillHeightReader)
                    .offset(y: -(Self.badgeSize / 2 + Spacing.sm + pillHeight / 2))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Circle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { tapped.toggle() } }
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
    }

    private var pill: some View {
        Text("\(marker.name) · \(speedText)")
            .font(.stCaption)
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .floatingCard(cornerRadius: Radius.pill)
    }

    private var speedText: String {
        String(format: "%.1f kn", marker.speedKn)
    }

    private var pillHeightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { pillHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, new in pillHeight = new }
        }
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
