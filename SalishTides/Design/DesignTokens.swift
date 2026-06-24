import SwiftUI

// MARK: - Color Tokens
//
// Semantic color names describe PURPOSE, not appearance.
// Groups: ocean palette, tide tendency, current speed scale.

extension Color {

    // -- Ocean palette (brand) --
    static let oceanDeep    = Color(red: 0.10, green: 0.22, blue: 0.36)  // #1A3A5C  migration bg
    static let oceanMid     = Color(red: 0.13, green: 0.40, blue: 0.67)  // #2166AB  primary
    static let oceanLight   = Color(red: 0.45, green: 0.68, blue: 0.82)  // #73AECF  secondary

    // -- Tide tendency (flood / ebb / slack) --
    static let tideFlood = Color(red: 0.13, green: 0.40, blue: 0.67)  // oceanMid — incoming
    static let tideEbb   = Color(red: 0.87, green: 0.45, blue: 0.08)  // #DE7314  — outgoing
    // slack = Color.secondary (system adaptive, sufficient for neutral)

    // -- Current speed — diverging blue→yellow→red scale --
    // Thresholds: <0.5  0.5–1.5  1.5–3.0  3.0–4.5  4.5+  knots
    static let currentCalm       = Color(red: 0.13, green: 0.40, blue: 0.67)  // muted blue
    static let currentLight      = Color(red: 0.45, green: 0.68, blue: 0.82)  // sky blue
    static let currentModerate   = Color(red: 0.98, green: 0.85, blue: 0.37)  // amber-yellow (sunlight-safe)
    static let currentStrong     = Color(red: 0.96, green: 0.43, blue: 0.26)  // orange-red
    static let currentVeryStrong = Color(red: 0.84, green: 0.19, blue: 0.15)  // deep red
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
    func floatingCard(cornerRadius: CGFloat = Radius.xl) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Elevation.cardBorderColor, lineWidth: Elevation.cardBorderWidth))
            .clipShape(shape)
            .shadow(color: Elevation.cardShadowColor,
                    radius: Elevation.cardShadowRadius,
                    y: Elevation.cardShadowYOffset)
    }
}

// MARK: - UIColor Helpers (for MapLibre NSExpression)
//
// MapLibre style layers use UIColor, not SwiftUI Color.
// Mirror the current speed scale here so MapLibreView can reference the same values.

extension UIColor {
    static let currentCalm       = UIColor(red: 0.13, green: 0.40, blue: 0.67, alpha: 1)
    static let currentLight      = UIColor(red: 0.45, green: 0.68, blue: 0.82, alpha: 1)
    static let currentModerate   = UIColor(red: 0.98, green: 0.85, blue: 0.37, alpha: 1)
    static let currentStrong     = UIColor(red: 0.96, green: 0.43, blue: 0.26, alpha: 1)
    static let currentVeryStrong = UIColor(red: 0.84, green: 0.19, blue: 0.15, alpha: 1)
}
