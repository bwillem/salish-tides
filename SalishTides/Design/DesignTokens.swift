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

    // Secondary "ink" for muted captions on the glass cards. Brighter than the
    // system `secondaryLabel` (≈60% in dark) so provenance text stays legible on
    // the dark material per principle #1, while still sitting below `.primary`.
    static let inkSecondary = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.80)
            : UIColor(white: 0, alpha: 0.58)
    })

    // -- Tide tendency (flood / ebb / slack) --
    // System hues so tendency tracks light / dark / contrast natively.
    static let tideFlood = Color.teal    // incoming — matches the app accent
    static let tideEbb   = Color.orange  // outgoing — system orange
    // slack = Color.secondary (system adaptive, sufficient for neutral)

    // The current-speed scale is rendered only on the map; its single source of
    // truth is UIColor.currentSpeedRamp (below). No SwiftUI Color mirror exists
    // because nothing consumes one — add it there if a SwiftUI use ever appears.
}

// MARK: - Typography Tokens
//
// Named styles wrap system fonts so call sites don't hard-code weights/sizes.
// All use SF Pro (default) or SF Mono where digits must align.

extension Font {
    // Splash / hero
    static let stDisplay  = Font.system(.largeTitle,  design: .default).weight(.bold)

    // Hero current-speed readout — the primary datum in the phase card. Large
    // monospaced digits so the value reads at a glance and doesn't jump while
    // scrubbing; the unit ("kn") rides smaller beside it.
    static let stReadout     = Font.system(.title,   design: .default).weight(.bold).monospacedDigit()
    static let stReadoutUnit = Font.system(.callout, design: .default).weight(.medium)

    // Tide phase label under the chart (and its tendency arrow)
    static let stPhase    = Font.system(.subheadline, design: .default)

    // Timeline date/time (monospaced so digits don't jump)
    static let stClock    = Font.system(.headline,    design: .default).monospacedDigit()

    // Secondary labels (chart number, phase in timeline)
    static let stCaption  = Font.system(.caption,     design: .monospaced)
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
            // Clip the content to the shape too: glassEffect masks the material to
            // the shape but not the view's own content, which the fallback clips.
            self.glassEffect(.regular, in: shape).clipShape(shape)
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

// MARK: - UIKit Mirrors (for MapLibre layers & annotation views)
//
// MapLibre style layers and annotation views use UIColor/UIFont, not SwiftUI
// Color/Font. Mirror the needed tokens here so the map references the same
// values as the SwiftUI chrome.

extension UIColor {
    /// Tide-station marker fill (badge + pulse ring). Deliberately NEUTRAL, not
    /// `brandAccent`: the marker is wayfinding, not the screen's focus, so it
    /// carries no hue that would compete with the current-speed ramp. It's the
    /// inverse of the theme's ink — white in Day, black in Night — which pairs
    /// with the `.label` glyph and rim for full contrast in either theme.
    static let stationMarker = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    }

    // Current-speed ramp for the map arrows, per theme. Buckets:
    // <0.5  <1.5  <3.0  <4.5  4.5+ knots (calm → very strong).
    // Seeded from Apple's system colors resolved for the theme, so the ramp
    // adapts like the rest of the UI; the only hand-tuned bucket is the Day
    // moderate one, darkened so it doesn't wash out on the pale basemap.
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

extension UIFont {
    /// UIKit mirror of `Font.stCaption` (caption, monospaced design) — on-map
    /// UIKit text (the station marker's name pill), so it matches the cards.
    /// Semantic base style, so it tracks Dynamic Type like the SwiftUI token.
    static var stCaption: UIFont {
        let base = UIFont.preferredFont(forTextStyle: .caption1)
        guard let descriptor = base.fontDescriptor.withDesign(.monospaced) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
