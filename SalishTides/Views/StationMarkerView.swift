import SwiftUI

/// The tide-station marker for the station driving the phase card, rendered as a
/// SwiftUI glass overlay *above* the map (positioned by the `MapLibreView`
/// coordinator via `StationMarkerPresenter.screenPoint`).
///
/// It is deliberately NOT an `MLNAnnotationView`: glass hosted inside MapLibre's
/// own view hierarchy composites flat (a `UIVisualEffectView` there can't sample
/// the Metal-rendered map behind it). As a sibling above the map it gets the
/// same real Liquid Glass as the phase card and timeline bar — its badge is the
/// shared `.floatingCard()` surface, clipped to a circle.
///
/// The badge carries the phase card's tendency arrow (↑ flood / ↓ ebb, a neutral
/// ↕ before the first reading) over a slow neutral pulse, plus a name pill that
/// reveals when the crosshair nears the station (pushed by the coordinator) or
/// on tap. The pulse holds still as a faint halo under Reduce Motion.
struct StationMarkerView: View {
    let tendency: CurrentPhase.Tendency?
    let name: String
    /// True while the map centre sits within the reticle of the station — one of
    /// the two pill-reveal triggers (the other is a tap).
    let nearCrosshair: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CrosshairPresenter.self) private var crosshair
    @State private var pulsing = false
    @State private var tapped = false
    @State private var pillHeight: CGFloat = 0

    private static let badgeSize: CGFloat = 26
    private static let hitSize: CGFloat = 44   // HIG minimum touch target
    private static let pulseScale: CGFloat = 2.2

    private var revealPill: Bool { nearCrosshair || tapped }

    var body: some View {
        ZStack {
            pulse
            badge
            if revealPill {
                pill
                    .background(pillHeightReader)
                    // Float the pill fully above the badge: place its centre half
                    // its own height plus an `sm` gap above the badge's top edge,
                    // so its bottom clears the badge in either Dynamic Type size.
                    .offset(y: -(Self.badgeSize / 2 + Spacing.sm + pillHeight / 2))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Circle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { tapped.toggle() } }
        .animation(.easeOut(duration: 0.2), value: revealPill)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tide station: \(name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("The tide chart shows predictions for this station.")
        // Start the pulse once shown; Reduce Motion keeps it a static halo.
        .onAppear { pulsing = !reduceMotion }
        // Re-arm the pulse: SwiftUI drops a `repeatForever` animation while the
        // app is backgrounded (and won't restart it on its own), and a
        // Reduce-Motion toggle has to switch the pulse between branches.
        .onChange(of: scenePhase) { _, phase in if phase == .active { rearmPulse() } }
        .onChange(of: reduceMotion) { _, _ in rearmPulse() }
        // Interacting with the map (pan/zoom/scrub) dismisses a tapped pill —
        // the overlay's stand-in for the annotation's old "tap open water to
        // dismiss" (a SwiftUI overlay can't see taps that land on the map).
        .onChange(of: crosshair.isEmphasized) { _, active in if active { tapped = false } }
    }

    /// Re-fires the pulse's `false→true` edge so its repeating animation restarts
    /// (SwiftUI won't on its own after a background/foreground or a branch swap).
    /// Stays a static halo under Reduce Motion.
    private func rearmPulse() {
        let animate = !reduceMotion
        pulsing = false
        Task { @MainActor in pulsing = animate }
    }

    /// Glyph on a glass circle — the shared `.floatingCard()` surface, so it's
    /// true glass over the map. `.primary` ink inverts with the theme (dark glyph
    /// in Day, light in Night) and reads against the translucent glass either way.
    private var badge: some View {
        Image(systemName: glyphName)
            .font(.stStationGlyph)
            .foregroundStyle(.primary)
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .floatingCard(cornerRadius: Self.badgeSize / 2)
    }

    private var pill: some View {
        Text(name)
            .font(.stCaption)
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .floatingCard(cornerRadius: Radius.pill)
    }

    /// Measures the pill's rendered height so it floats exactly above the badge
    /// regardless of Dynamic Type size.
    private var pillHeightReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { pillHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, new in pillHeight = new }
        }
    }

    @ViewBuilder
    private var pulse: some View {
        let ring = Circle()
            .fill(Color(uiColor: .stationMarker))
            .frame(width: Self.badgeSize, height: Self.badgeSize)
            .allowsHitTesting(false)
        if reduceMotion {
            // Static faint halo — distinct without motion.
            ring.opacity(0.18).scaleEffect(1.5)
        } else {
            ring
                .opacity(pulsing ? 0 : 0.5)
                .scaleEffect(pulsing ? Self.pulseScale : 1)
                .animation(.easeOut(duration: 2.6).repeatForever(autoreverses: false),
                           value: pulsing)
        }
    }

    private var glyphName: String {
        switch tendency {
        case .flood: "arrow.up"
        case .ebb: "arrow.down"
        case nil: "arrow.up.and.down"
        }
    }
}
