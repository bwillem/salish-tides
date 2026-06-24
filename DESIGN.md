# Salish Tides — Design System

Living design reference for the Salish Tides iOS/iPadOS app.  
**Update this document whenever a design decision is made or a token value changes.**

---

## 1. Vision & Principles

**What it is:** A fully offline tidal current planning tool for sailors in the Salish Sea. The map is the entire product — everything else is a thin information layer on top.

**Who uses it:** Sailors at anchor or underway. Primary context = bright outdoor daylight, gloves possible, one hand on the wheel. iPad Pro at the helm.

**Design principles, in priority order:**

| # | Principle | What it means in practice |
|---|-----------|--------------------------|
| 1 | **Legible at arm's length in sunlight** | Minimum 7:1 contrast on all text over the map. No subtle glows or low-opacity labels. |
| 2 | **Map first** | UI chrome is an overlay, not a frame. Overlays must be dismissible or minimal. Never occlude more than ~15% of the map. |
| 3 | **Instant comprehension** | A sailor should read current state (time, phase, speed at crosshair) in under 2 seconds without navigating anywhere. |
| 4 | **Trustworthy, not flashy** | Nautical instruments are matte and purposeful. No gradients, no animations that delay information. |
| 5 | **Offline-first** | No loading spinners for data; all state should be local. Perceived performance = real performance here. |

---

## 2. Color System

### 2.1 Semantic Palette

All colors live in `SalishTides/Design/DesignTokens.swift` as `Color` extensions.  
**Never use hex literals or `Color(red:green:blue:)` calls outside of `DesignTokens.swift`.**

#### Ocean Palette (brand)
| Token | Hex | Use |
|-------|-----|-----|
| `.oceanDeep` | `#1A3A5C` | Migration/splash background |
| `.oceanMid` | `#2166AB` | Primary brand color, flood indicator |
| `.oceanLight` | `#73AECF` | Secondary accent, light current arrows |

#### Tide Tendency
| Token | Hex | Meaning |
|-------|-----|---------|
| `.tideFlood` | `#2166AB` | Incoming tide (same as oceanMid) |
| `.tideEbb` | `#DE7314` | Outgoing tide — warm amber |
| `Color.secondary` | system | Slack water / neutral |

Flood = blue (water rising, ocean filling). Ebb = amber (receding, warmth). This mapping is consistent with traditional tidal imagery and avoids red/green colorblindness conflicts.

#### Current Speed Scale (diverging)

Used exclusively for MapLibre arrow rendering. Matches scientific convention (cool→warm diverging scale).

| Token | Hex | Speed range | UIColor alias |
|-------|-----|-------------|---------------|
| `.currentCalm` | `#2166AB` | < 0.5 kn | `UIColor.currentCalm` |
| `.currentLight` | `#73AECF` | 0.5 – 1.5 kn | `UIColor.currentLight` |
| `.currentModerate` | `#FAD95E` | 1.5 – 3.0 kn | `UIColor.currentModerate` |
| `.currentStrong` | `#F56E43` | 3.0 – 4.5 kn | `UIColor.currentStrong` |
| `.currentVeryStrong` | `#D73026` | ≥ 4.5 kn | `UIColor.currentVeryStrong` |

> **Sunlight warning:** The original moderate-current color was `#FFFFBF` (near-white yellow) which is nearly invisible against a light basemap and in sunlight. It has been replaced with `#FAD95E` (amber-yellow) which passes 3:1 contrast against a white background. Verify this on a real iPad in daylight before shipping.

> **Colorblindness note:** The blue→amber→red ramp is partially accessible (avoids pure red/green). The calm→light transition (both blue) may be hard to distinguish for some users. Future: add line-weight encoding as a secondary cue.

### 2.2 System Colors & Materials

- **Overlay backgrounds:** `.ultraThinMaterial` (current, good — adapts to dark mode and blurs the map behind)
- **Text over map:** `.primary` / `.secondary` work in both light and dark because they adapt. Prefer these over hardcoded white.
- **Text on `oceanDeep`:** Hardcode `.white` — the background is fixed dark.

### 2.3 Dark Mode

The app currently has no explicit dark mode treatment beyond system materials.

**Recommended approach (next iteration):**
- Migration screen: `oceanDeep` already looks correct in dark mode (dark background is appropriate)
- PhaseIndicator capsule: `.ultraThinMaterial` auto-adapts ✓
- Timeline bar: `.ultraThinMaterial` auto-adapts ✓
- Current vector arrows: the color scale should remain constant regardless of map light/dark, since the basemap is the context

---

## 3. Typography

Named styles live in `DesignTokens.swift` as `Font` extensions.

| Token | Base style | Weight | Role |
|-------|-----------|--------|------|
| `.stDisplay` | `.largeTitle` | Bold | Splash screen headline |
| `.stHeadline` | `.subheadline` | Bold | Phase name in capsule badge |
| `.stClock` | `.headline` | Regular + monospacedDigit | Date/time in timeline |
| `.stCaption` | `.caption` | Regular | Chart number, secondary labels |
| `.stMono` | `.caption2` | Mono + monospacedDigit | Speed readout, offset label |

**Design rationale:**
- All digit-bearing labels use `.monospacedDigit()` so the layout doesn't shift as numbers change during scrubbing
- SF Pro is the only acceptable typeface — it's optimized for iPad display legibility and respects Dynamic Type
- No custom fonts: custom fonts require font loading, add bundle weight, and bypass system accessibility scaling

**Dynamic Type:** All `Font` tokens use semantic styles (`.headline`, `.caption`, etc.) which automatically scale with the user's text size preference. Do not use `.system(size: 14)` — fixed-point sizes opt out of Dynamic Type.

---

## 4. Spacing & Layout

### 4.1 Spacing Scale

From `Spacing` enum in `DesignTokens.swift`:

| Token | Value | Common use |
|-------|-------|-----------|
| `Spacing.xxs` | 2 pt | Icon/text tight spacing |
| `Spacing.xs` | 4 pt | Internal component padding |
| `Spacing.sm` | 8 pt | Between related elements |
| `Spacing.md` | 14 pt | Horizontal padding in capsule/bar |
| `Spacing.lg` | 16 pt | Screen edge margin |
| `Spacing.xl` | 24 pt | Between sections |
| `Spacing.xxl` | 32 pt | Large vertical gaps |

### 4.2 iPad Layout Grid

- **Safe area:** Respect all four safe areas (status bar, home indicator, multitasking sidebars)
- **Screen edge margin:** `Spacing.lg` (16 pt) minimum from any safe-area edge
- **Map chrome budget:** Timeline bar + phase capsule together should not exceed 15% of vertical screen height on the smallest supported iPad (iPad 10th gen, 1180×820 pt landscape)

### 4.3 Touch Targets

**Minimum:** 44×44 pt (Apple HIG). 
**Recommended for gloved/outdoor use:** 48×48 pt.

The current `← Hr` / `Hr →` step buttons with `.controlSize(.small)` likely fall below 44 pt. Flag for audit.

### 4.4 Overlay Placement

```
┌──────────────────────────────────────────────────────────────┐
│  [status bar]                              [PhaseIndicator]  │  ← top-right, safe area + 8pt
│                                                              │
│                        MAP                                   │
│                       (full bleed)                           │
│                        [crosshair]                           │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │               TimelineControlView                      │  │  ← ultraThinMaterial bar
│  │  ← Hr    Jun 24 · 15:00    Hr →                       │  │
│  │  [Now]  [════════●════════]  +2h                      │  │
│  └────────────────────────────────────────────────────────┘  │
│  [home indicator]                                            │
└──────────────────────────────────────────────────────────────┘
```

---

## 5. Component Anatomy

### 5.1 PhaseIndicator Capsule

**Location:** Top-right, `.padding(.trailing)` + `.padding(.top, 8)` from safe area  
**Shape:** `Capsule()` fill with `.ultraThinMaterial`  
**Padding:** 14 pt horizontal, 8 pt vertical

**Anatomy:**
```
[icon] [Phase Name (bold subheadline)]
       [Chart N of 43 · X.X kn ✛ (caption2 mono)]
```

**States:**
- **Normal:** flood icon (arrow.up.circle.fill, `.tideFlood`) or ebb icon (arrow.down.circle.fill, `.tideEbb`)
- **No selection:** hidden (conditional on `vm.currentSelection != nil`)
- **Speed available:** shows crosshair speed with `✛` suffix
- **Speed unavailable:** shows only chart/phase

**Open design issues:**
- The `✛` suffix character is non-standard and may not read naturally on VoiceOver
- "Chart N of 43" is Vol 1-specific; will need updating when multi-volume support lands

### 5.2 Timeline Control Bar

**Location:** Bottom, full-width, above home indicator  
**Background:** `.ultraThinMaterial` (not a Card; intentionally frameless)  
**Padding:** 10 pt horizontal, 12 pt bottom, 10 pt top

**Anatomy (top row):**
```
[← Hr]          [Date Mon DD · HH:MM]          [Hr →]
                [Chart N · Phase Name]
```

**Anatomy (bottom row):**
```
[Now]  [════════════════●═══════]  [+Nh]
```

**Slider:** ±12 hour range, 1-hour steps. The `±12h` range covers one full tidal day in either direction, which is appropriate.

**Open design issues:**
- "← Hr" and "Hr →" are text labels that don't convey symbol semantics; consider SF Symbols `chevron.left` / `chevron.right` with "1 hr" accessibility label
- The `Now` button uses `.bordered` style — fine for MVP, but could become a secondary-action pill with `.tideFlood` tint
- No haptic feedback on slider step or button press — add `UIImpactFeedbackGenerator` at step boundaries

### 5.3 Crosshair

**Location:** Centered in map, non-interactive (`allowsHitTesting(false)`)  
**Design:** 22 pt circle + 4 tick marks at 12/18 pt (gap + reach from center)  
**Color:** `.white.opacity(0.75)`

**Open design issue:** Pure white at 75% opacity may wash out against light-colored map tiles (white water, ice). Consider a thin black shadow/stroke for contrast universality.

### 5.4 Current Vector Arrows

Rendered by MapLibre, not SwiftUI. Color is controlled by `speedColorExpression()` in `MapLibreView.Coordinator`.

**Line weight by speed:**
| Speed | Shaft width | Barb width |
|-------|-------------|------------|
| < 1.5 kn | 1.0 pt | 0.8 pt |
| 1.5–3.0 kn | 1.8 pt | 1.4 pt |
| ≥ 3.0 kn | 3.0 pt | 2.5 pt |

**Design intent:** Both color and weight encode speed (redundant encoding), which helps colorblind users and improves sunlight readability.

**Arrow geometry:** ±25° barb spread, barb length = 70% of half-shaft. This is close to standard meteorological wind barb convention, which sailors recognize.

### 5.5 Migration/Splash Screen

**Background:** `.oceanDeep` (#1A3A5C)  
**Icon:** `water.waves` at 48 pt, `.white.opacity(0.8)`  
**Title:** "Salish Tides" in `.stDisplay` white  
**Progress:** System `ProgressView(.linear)` tinted white, 280 pt wide  
**Caption:** "Loading charts… N%" in `.stMono`-equivalent caption

**Note:** This screen shows only on first launch (migration). Second launch goes directly to the map. No need to optimize for repeat views.

---

## 6. Accessibility

### 6.1 Contrast Requirements

Target: **WCAG AA** minimum everywhere, **AAA (7:1)** for map-overlaid text given outdoor use.

| Element | Foreground | Background | Current ratio | Target |
|---------|-----------|------------|---------------|--------|
| Phase name | `.primary` (dark) | `.ultraThinMaterial` | ~varies | ≥ 4.5:1 |
| Date/time | `.primary` | `.ultraThinMaterial` | ~varies | ≥ 4.5:1 |
| Speed readout | `.primary` | `.ultraThinMaterial` | ~varies | ≥ 4.5:1 |
| Migration title | white | `#1A3A5C` | ~12:1 ✓ | 7:1 |
| Current: moderate | `#FAD95E` | white map | ~2.5:1 ⚠️ | 3:1 |

> The moderate-current arrow color does not meet 3:1 on white. This is acceptable for non-text decorative elements under WCAG, but worth revisiting given outdoor use.

### 6.2 VoiceOver Labels

Elements that need explicit accessibility labels (not yet implemented):

```swift
// PhaseIndicatorView icon
Image(systemName: tendencyIcon(sel.tendency))
    .accessibilityLabel(sel.tendency == .flood ? "Flood tide" : "Ebb tide")

// Timeline step buttons
Button("← Hr") { ... }
    .accessibilityLabel("Step back one hour")

Button("Hr →") { ... }
    .accessibilityLabel("Step forward one hour")

// Now button
Button("Now") { ... }
    .accessibilityLabel("Jump to current time")

// Slider
Slider(value: $offsetHours, in: -12...12, step: 1)
    .accessibilityLabel("Time offset")
    .accessibilityValue("\(Int(offsetHours)) hours")
```

### 6.3 Dynamic Type

All text uses semantic font styles → scales automatically. Verify at "Accessibility Extra Extra Extra Large" that the timeline bar doesn't clip. If it does, use `minimumScaleFactor(0.75)` on date/time labels before truncating.

### 6.4 Reduce Motion

The app has no animations currently. When animations are added (e.g., arrow fade transitions between charts), wrap in:
```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion
```

---

## 7. iOS/iPadOS Platform Notes

### iPad-specific

- The primary target is iPad — test all layouts on iPad Pro 12.9" and iPad 10th gen
- Support both landscape and portrait (sailors may dock in portrait)
- Consider `UISplitViewController`-equivalent for future detail panels (current info, legend)
- Stage Manager / multitasking: the map should remain functional in 2/3 split view

### iOS 17+ Features Available

- `@Observable` macro (already used via `MapViewModel`)
- `SwiftData` (not used — GRDB preferred for performance reasons)
- `scrollTargetBehavior` for potential future chart picker
- `backgroundStyle` modifier for cleaner material application

### iOS 26 / Liquid Glass (Future)

Apple introduced Liquid Glass materials in iOS 26. The current `.ultraThinMaterial` will automatically gain the new appearance on iOS 26 devices. This is an advantage — no code changes needed for the new system aesthetic. Monitor for visual regressions after iOS 26 adoption.

---

## 8. Design Iteration Log

| Date | Change | Rationale |
|------|--------|-----------|
| 2026-06-24 | Created design system, extracted tokens to `DesignTokens.swift` | Baseline |
| 2026-06-24 | Changed moderate-current color from `#FFFFBF` to `#FAD95E` | Near-white yellow invisible in sunlight on light basemap |
| 2026-06-24 | Changed ebb color from system `.orange` to `#DE7314` | More nautical, less generic; differentiates from warning/error orange |

---

## 9. Open Design Backlog

| Priority | Item | Notes |
|----------|------|-------|
| High | Real nautical basemap | Current stub-style.json is solid blue. Need PMTiles + proper chart style. Until this ships, all visual design is provisional. |
| High | Crosshair contrast on light map | White-on-white will be invisible. Add dark stroke or shadow. |
| Medium | VoiceOver labels | See §6.2 — none of the overlay controls have explicit labels yet |
| Medium | Touch target audit | Step buttons likely < 44×44 pt |
| Medium | Speed legend | Users need a legend to understand the 5-color current scale |
| Medium | Sunlight contrast validation | Test `.currentModerate` (#FAD95E) on device in daylight |
| Low | Haptic feedback | Add impact feedback to slider steps and Now button |
| Low | Dark mode explicit treatment | Materials handle it, but test the full dark-mode flow |
| Low | Portrait layout | Verify timeline + phase capsule don't overlap in portrait on smaller iPads |
