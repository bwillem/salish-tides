import SwiftUI

// MARK: - Color Tokens
//
// Semantic color names describe PURPOSE, not appearance.
// Groups: ocean palette, tide tendency, current speed scale.

extension Color {

    // -- App accent --
    // Drives the global `.tint` and every brand-accent chrome surface (the
    // "Now" pill, live dot, tape cursor, chart fill). System teal is a native,
    // self-adapting marine hue — its light / dark / increased-contrast variants
    // come for free, so accent chrome tracks the system the way Apple's apps do.
    static let brandAccent = Color.teal

    // -- Adaptive surfaces (Day / Night themes) --
    // Splash & migration background: pale sky in Day, deep ocean in Night.
    // Brand colors below stay constant; only true surfaces adapt.
    static let appBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.22, blue: 0.36, alpha: 1)   // oceanDeep
            : UIColor(red: 0.86, green: 0.91, blue: 0.95, alpha: 1)   // pale sky
    })

    // -- Tide tendency (flood / ebb / slack) --
    // System hues so tendency tracks light / dark / contrast natively.
    static let tideFlood = Color.teal    // incoming — matches the app accent
    static let tideEbb   = Color.orange  // outgoing — system orange
    // slack = Color.secondary (system adaptive, sufficient for neutral)

    // -- Current speed — diverging blue→yellow→red scale --
    // Thresholds: <0.5  0.5–1.5  1.5–3.0  3.0–4.5  4.5+  knots
    // Seeded from Apple's system colors; the map ramp (UIColor.currentSpeedRamp)
    // is the rendered source of truth — these mirror it for any SwiftUI use.
    static let currentCalm       = Color.blue
    static let currentLight      = Color.teal
    static let currentModerate   = Color.yellow
    static let currentStrong     = Color.orange
    static let currentVeryStrong = Color.red
}

// MARK: - Typography Tokens
//
// Named styles wrap system fonts so call sites don't hard-code weights/sizes.
// All use SF Pro (default) or SF Mono where digits must align.

extension Font {
    // Splash / hero
    static let stDisplay  = Font.system(.largeTitle,  design: .default).weight(.bold)

    // Phase name headline in the capsule badge
    static let stHeadline = Font.system(.subheadline, design: .default).weight(.bold)

    // Timeline date/time (monospaced so digits don't jump)
    static let stClock    = Font.system(.headline,    design: .default).monospacedDigit()

    // Secondary labels (chart number, phase in timeline)
    static let stCaption  = Font.system(.caption,     design: .monospaced)

    // Speed readout, offset label — fixed-width data
    static let stMono     = Font.system(.caption2,    design: .monospaced).monospacedDigit()
}

// MARK: - Spacing Scale
//
// 4 pt base grid. Use these instead of magic numbers in padding/spacing calls.

enum Spacing {
    static let xxs: CGFloat =  2
    static let xs:  CGFloat =  4
    static let sm:  CGFloat =  8
    static let md:  CGFloat = 14
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Corner Radius Scale

enum Radius {
    static let sm:   CGFloat =  8
    static let md:   CGFloat = 12
    static let lg:   CGFloat = 16
    static let xl:   CGFloat = 28  // floating glass cards (phase panel, timeline bar)
    static let pill: CGFloat = 999  // for Capsule()-equivalent rounded rects
}

// MARK: - Floating Card
//
// The single "glass card" surface used for every floating overlay (phase
// panel, timeline bar). Ultra-thin material, continuous-rounded corners, a
// hairline edge, and a soft drop shadow to lift it off the map. Use this
// modifier rather than re-deriving the treatment so the surfaces stay in sync.

enum Elevation {
    static let cardShadowColor   = Color.black.opacity(0.25)
    static let cardShadowRadius: CGFloat = 12
    static let cardShadowYOffset: CGFloat = 4
    static let cardBorderColor   = Color.white.opacity(0.12)
    static let cardBorderWidth: CGFloat = 0.5
}

extension View {
    // The floating overlays (phase panel, timeline bar) live in the navigation
    // layer above the map — exactly what Liquid Glass is for. On iOS 26+ we use
    // the native `.glassEffect`, which supplies translucency, edge highlight and
    // shadow as one adaptive material. On iOS 17–25 we fall back to the prior
    // hand-built ultra-thin-material treatment so older devices look unchanged.
    @ViewBuilder
    func floatingCard(cornerRadius: CGFloat = Radius.xl) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Elevation.cardBorderColor, lineWidth: Elevation.cardBorderWidth))
                .clipShape(shape)
                .shadow(color: Elevation.cardShadowColor,
                        radius: Elevation.cardShadowRadius,
                        y: Elevation.cardShadowYOffset)
        }
    }
}

// MARK: - UIColor Helpers (for MapLibre NSExpression)
//
// MapLibre style layers use UIColor, not SwiftUI Color.
// Mirror the current speed scale here so MapLibreView can reference the same values.

extension UIColor {
    // Current-speed ramp for the map arrows, per theme. Buckets:
    // <0.5  <1.5  <3.0  <4.5  4.5+ knots (calm → very strong).
    // Night is tuned for the dark basemap (bright); Day is darker / more
    // saturated so every arrow — especially the mid amber — reads on the light
    // basemap instead of washing out.
    static func currentSpeedRamp(dark: Bool) -> [UIColor] {
        // Native system hues for the diverging calm → very-strong scale.
        // System colors already brighten in dark mode and darken in light mode
        // (the same legibility intent the old hand-tuned arrays encoded), so we
        // resolve each for the map's current theme and hand MapLibre concrete,
        // theme-correct colors. Verified on both basemaps for arrow legibility.
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let ramp = [
            UIColor.systemBlue,    // calm
            UIColor.systemTeal,    // light
            UIColor.systemYellow,  // moderate
            UIColor.systemOrange,  // strong
            UIColor.systemRed,     // very strong
        ].map { $0.resolvedColor(with: traits) }
        guard !dark else { return ramp }
        // On the pale Day basemap, system yellow — the diverging midpoint — lacks
        // contrast against light water, so darken just the moderate bucket toward
        // amber. Verified against the light basemap; the rest stay pure system.
        var light = ramp
        light[2] = UIColor(red: 0.80, green: 0.55, blue: 0.05, alpha: 1)  // amber
        return light
    }
}
