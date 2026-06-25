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

#### Current Speed Scale (diverging, per-theme)

Used exclusively for MapLibre arrow rendering (cool→warm diverging scale). The
single source of truth is `UIColor.currentSpeedRamp(dark:)` — a 5-stop ramp that
differs by theme so each arrow contrasts against its basemap.

| Bucket | Speed | Night (dark map) | Day (light map) |
|--------|-------|------------------|-----------------|
| calm | < 0.5 kn | `#2166AB` muted blue | `#14577D` deep blue |
| light | 0.5 – 1.5 kn | `#73AED1` sky blue | `#2685BC` ocean blue |
| moderate | 1.5 – 3.0 kn | `#FAD95E` amber | `#CC8500` dark amber |
| strong | 3.0 – 4.5 kn | `#F56E43` orange-red | `#DB591A` burnt orange |
| very strong | ≥ 4.5 kn | `#D73026` deep red | `#B81C19` deep red |

> **Why per-theme:** the bright Night ramp's mid amber (`#FAD95E`) and sky blue
> wash out on the light Day basemap. The Day ramp darkens/saturates every stop
> so the amber especially stays legible. (The `.current*` SwiftUI `Color` tokens
> mirror the Night values for any future legend.)

> **Colorblindness note:** The blue→amber→red ramp is partially accessible (avoids pure red/green). The calm→light transition (both blue) may be hard to distinguish for some users. Future: add line-weight encoding as a secondary cue.

### 2.2 System Colors & Materials

- **Overlay backgrounds:** `.ultraThinMaterial` (adapts to dark mode and blurs the map behind). Applied via the **Floating Card** surface — see §4.1b.
- **Text over map:** `.primary` / `.secondary` work in both light and dark because they adapt. Prefer these over hardcoded white.
- **Text on `oceanDeep`:** Hardcode `.white` — the background is fixed dark.

### 2.3 Day / Night Themes

The app follows the **system appearance** and ships two full themes — **Day**
(light) and **Night** (dark). Every surface adapts:

| Surface | Day (light) | Night (dark) |
|---------|-------------|--------------|
| Basemap | CARTO `light_all` raster (`stub-style-light.json`) | CARTO `dark_all` raster (`stub-style-dark.json`) |
| Splash / migration bg | `Color.appBackground` — pale sky | `Color.appBackground` — `oceanDeep` |
| Floating cards | `.ultraThinMaterial` (auto) | `.ultraThinMaterial` (auto) |
| Ink (card text, chart, tape) | `.primary` / `.secondary` (auto → dark ink) | `.primary` / `.secondary` (auto → light ink) |
| Crosshair | `.primary` reticle + `Color(.systemBackground)` halo (inverse) | same, inverts automatically |
| Current arrows | `UIColor.currentSpeedRamp(dark: false)` — darker, saturated (amber reads on light) | `currentSpeedRamp(dark: true)` — brighter ramp for the dark basemap |

**Rules**
- **Never hardcode `.white`** in Canvas views — use `.primary`/`.secondary` so
  the chart and tape ink flip with the theme. The `GraphicsContext` resolves
  semantic colors against the view's color scheme.
- **Adaptive colors live as one token** (`Color.appBackground`, defined with a
  `UIColor` dynamic provider in `DesignTokens.swift`); the `oceanMid` chart fill
  stays constant, while the current-speed ramp is per-theme (`currentSpeedRamp`).
- The basemap switches via `MapLibreView` observing `@Environment(\.colorScheme)`
  and swapping `styleURL`; vectors are re-applied on the new style.

The current-speed arrow ramp is **per-theme** (`UIColor.currentSpeedRamp(dark:)`,
the single source of truth — re-evaluated whenever the style reloads). The Day
ramp is darker and more saturated so the mid "amber" arrow reads on the light
basemap rather than washing out; the Night ramp stays bright for the dark map.

### 2.4 Map Style (offline-first, online-enhanced)

The basemap follows an **offline-first, progressively-enhanced** model: the app
must work 100% offline, but light up richer maps when a connection exists
(Starlink, dock WiFi). User-selectable in **Settings → Map Style** (`Basemap`).

| Style | Source | Offline? | Light / Dark |
|-------|--------|----------|--------------|
| **Standard** | Bundled stub (`stub-style-{light,dark}.json`) | Always (the offline baseline) | per-theme stubs |
| **Ocean** | MapTiler bathymetry (`ocean-{light,dark}.json`) | After viewing online (ambient cache) | bundled pair |
| **Satellite** | MapTiler imagery (`satellite.json`) | After viewing online | single (imagery is theme-agnostic) |

**Key mechanics:**
- **Style JSONs are bundled** in `Resources/styles/` (tiny text). Each carries a
  `{{MAPTILER_KEY}}` placeholder; `MapStyleLoader` injects `MapConfig.maptilerKey`
  at load and writes a temp file MapLibre loads. **The key is never committed** —
  it lives in the gitignored `Config/Secrets.xcconfig`. No key → falls back to the
  Standard stub, so a fresh checkout always renders.
- **Light + dark are bundled together** so a Day→Night flip works offline: if a
  sailor cached Ocean in daylight then loses signal at dusk, the dark Ocean still
  renders (it reuses the same cached tiles, only the colour JSON differs).
- **Caching is automatic** via MapLibre's ambient cache (raised to 256 MB in
  `MapLibreView`). Tiles are cached as you view them online — no explicit
  download/progress. Coverage = waters you've actually looked at.
- **Reachability** (`NetworkMonitor`, `NWPathMonitor`) gates the picker: a network
  style is selectable only when online **or** already cached
  (`AppSettings.offlineReadyStyles`, recorded when a style is shown online).
  Otherwise the row is disabled with an **"Online only"** caption — but any style
  you've already used stays swappable offline.
- The **dark Ocean** variant is an authored colour remap of the light Ocean style
  (same bathymetry tiles, darkened water/land, lightened labels).

> The Standard stub still streams CARTO rasters, so it is not *truly*
> offline yet — a real bundled baseline (PMTiles bathymetry, backlog #1) is the
> next milestone. MapTiler online is the enhancement layer; a future SalishSeaCast
> current model will hang off the same `NetworkMonitor` plumbing.

---

## 3. Typography

Named styles live in `DesignTokens.swift` as `Font` extensions.

| Token | Base style | Weight | Role |
|-------|-----------|--------|------|
| `.stDisplay` | `.largeTitle` | Bold | Splash screen headline |
| `.stHeadline` | `.subheadline` | Bold | Phase name in panel |
| `.stClock` | `.headline` | Regular + monospacedDigit | Date/time in timeline |
| `.stCaption` | `.caption` | Regular | Secondary labels |
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
| `Spacing.md` | 14 pt | Card inner padding |
| `Spacing.lg` | 16 pt | Screen edge margin |
| `Spacing.xl` | 24 pt | Between sections |
| `Spacing.xxl` | 32 pt | Large vertical gaps |

### 4.1a Corner Radius

From the `Radius` enum in `DesignTokens.swift`. All card-level surfaces use the
**continuous** (squircle) corner curve, not the default circular one.

| Token | Value | Common use |
|-------|-------|-----------|
| `Radius.sm` | 8 pt | Small controls, inner chips |
| `Radius.md` | 12 pt | Buttons, secondary surfaces |
| `Radius.lg` | 16 pt | Mid-size panels |
| `Radius.xl` | 28 pt | **Floating glass cards** (phase panel, timeline bar) |
| `Radius.pill` | 999 | Capsule-equivalent rounded rects |

### 4.1b Elevation & The Floating Card

The single surface treatment for every floating overlay. Defined once as the
`.floatingCard()` view modifier (`DesignTokens.swift`) and the `Elevation`
tokens — **do not re-derive it per view**, so the phase panel and timeline bar
stay visually identical.

| Property | Value |
|----------|-------|
| Material | `.ultraThinMaterial` |
| Corner | `Radius.xl` (28 pt), `.continuous` |
| Border | `Elevation.cardBorderColor` = white @ 12%, 0.5 pt hairline (`strokeBorder`) |
| Shadow | `Elevation.cardShadowColor` = black @ 25%, radius 12, y-offset 4 |
| Clip | content clipped to the rounded shape so nothing overflows the corners |

```swift
SomeContent()
    .frame(width: 248)   // size first
    .floatingCard()      // then apply the surface
```

**Why a shared modifier:** before harmonization the timeline bar was an
edge-to-edge frameless material slab while the phase panel was a 16 pt capsule —
they read as two different systems. Floating both on the same card makes them a
deliberate pair bracketing the map, and the map currents stay visible around and
beneath each card.

### 4.2 iPad Layout Grid

- **Safe area:** Respect all four safe areas (status bar, home indicator, multitasking sidebars)
- **Screen edge margin:** `Spacing.lg` (16 pt) minimum from any safe-area edge
- **Map chrome budget:** Timeline bar + phase panel together should not exceed 15% of vertical screen height on the smallest supported iPad (iPad 10th gen, 1180×820 pt landscape)

### 4.3 Touch Targets

**Minimum:** 44×44 pt (Apple HIG). 
**Recommended for gloved/outdoor use:** 48×48 pt.

The **Now** button uses `.controlSize(.small)` and may fall below 44 pt — audit. The time tape is 36 pt tall but spans the full card width, so its drag target is large.

### 4.4 Overlay Placement

Both overlays are **floating cards** (§4.1b) — inset from the screen edges with
the map visible around and beneath them.

```
┌──────────────────────────────────────────────────────────────┐
│  [status bar]                          ╭────────────────╮    │  ← top-right floating card
│                                        │  tide chart    │    │     (safe area + 8pt)
│                        MAP             │  Phase · kn ✛  │    │
│                       (full bleed)     ╰────────────────╯    │
│                        [crosshair]                           │
│                                                              │
│        ╭──────────────────────────────────────────────╮      │  ← floating card, inset 16pt
│        │            Jun 24 at 15:00                    │      │
│        │  [Now]   ·····│····· (time tape) ·····        │      │
│        ╰──────────────────────────────────────────────╯      │
│  [home indicator]                                            │
└──────────────────────────────────────────────────────────────┘
```

---

## 5. Component Anatomy

### 5.1 PhaseIndicator Panel

**Location:** Top-right, `.padding(.trailing)` + `.padding(.top, 8)` from safe area  
**Surface:** Floating card (§4.1b), fixed `width: 248`  
**Composition:** two groups separated by spacing alone (no divider) — the tide
chart + its phase state on top, then the current-speed hero.

**Anatomy:**
```
╭──────────────────────────────╮
│  [TideChartView — 108 pt]     │  ← station name · datum, curve, cursor height
│  ↑ Phase Name                 │  ← tide group: tendency + phase, tied to chart
│                               │  ← separation by spacing (Spacing.lg), no line
│  ✛ X.X kn                     │  ← HERO: crosshair speed (.stReadout, large/bold)
╰──────────────────────────────╯
```

**Information hierarchy & grouping:**
- The **current speed at the crosshair is the primary datum** — large, bold
  `.stReadout` with a smaller `.stReadoutUnit` unit beside it. It scales down
  (`minimumScaleFactor`) rather than wrap at large Dynamic Type (fixed 248 pt).
- The **tide phase + tendency** is conceptually part of the chart (it names the
  state the curve shows), so it sits **directly under the chart** as one group.
- The two groups are separated by **spacing only** — no hairline divider — in
  keeping with the matte/purposeful principle (§1). The size jump from the small
  phase label to the big readout reinforces the break.

**States:**
- **Normal:** plain tendency arrow on the phase line — `arrow.up` `.tideFlood` (flood) or `arrow.down` `.tideEbb` (ebb). Not the filled-circle variants.
- **No selection:** hidden (conditional on `vm.currentSelection != nil`)
- **Crosshair on land / off coverage:** hero shows an em dash (`—`) — no speed to report
- **Tide data unavailable:** chart shows a "Tide data unavailable" placeholder

**Speed readout:** value is formatted from `AppSettings.speedUnit` so it honours
the user's unit (kn / km·h / m·s — see §9). The crosshair association uses the
`scope` SF Symbol, not the former non-standard `✛` glyph (which did not read
naturally on VoiceOver). The accessibility label leads with the speed to match
the visual hierarchy.

### 5.2 Timeline Control Bar

**Location:** Bottom, floating, inset `Spacing.lg` (16 pt) from the side edges, above the home indicator  
**Surface:** Floating card (§4.1b)  
**Inner padding:** `Spacing.lg` horizontal, `Spacing.md` vertical

**Anatomy (top row):**
```
[Now]            [Date Mon DD at HH:MM]            (balance)
                 [Phase Name]
```

**Anatomy (bottom row):**
```
·····│····· Time Tape (fixed centre cursor, ticks scroll, snaps to hour) ·····
```

**Time tape:** ±12 hour range, snaps to whole hours (data is hourly). The fixed
centre cursor turns amber (`.tideEbb`) when offset from "now"; the **Now** button
tints amber when not at the present. The `±12h` range covers one full tidal day
in either direction. See `TapeSliderView`.
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

### 5.6 Settings Button & Sheet

**Entry point** (`SettingsButton`, in `ContentView`): a floating gear
(`gearshape`) in the **top-left**, mirroring the phase panel top-right so the two
upper corners read as a deliberate pair. Uses the shared `.floatingCard()`
surface at `Radius.lg` and a fixed **44×44 pt** frame — meets the HIG minimum
target. Inset `.padding(.leading)` + `Spacing.sm` from the safe area.

**Sheet** (`SettingsView`): a standard grouped `Form` in a `NavigationStack`,
following the iOS HIG settings pattern — sections of related controls, system
`Picker`/`Toggle`, inline navigation title, single confirming **Done** button
(`.confirmationAction`).

```
Settings                                    Done
┌──────────────────────────────────────────────┐
│  UNITS                                         │
│   Current speed                      Knots ⌄   │
│   Tide height                       Metres ⌄   │
│  MAP & DISPLAY                                  │
│   Crosshair                               ●──  │
│  APPEARANCE                                     │
│   [ System | Light | Dark ]                    │
│  ABOUT                                          │
│   Version                          1.0 (1)     │
│   Data Sources                            >    │
└──────────────────────────────────────────────┘
```

**Data Sources** (`DataSourcesView`, pushed from About): NOAA CO-OPS / CHS IWLS
tide attribution, the Salish Sea Tidal Current Atlas, MapLibre basemap credit, and the
"not for navigation" disclaimer. In-app provenance is expected at App Store
review for a navigation aid.

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

The overlay controls expose explicit labels (implemented):

| Control | Treatment |
|---------|-----------|
| Time tape (`TapeSliderView`) | Adjustable element — label "Forecast time", value reads the offset ("2 hours ahead of now" / "Now"), swipe up/down steps ±1 hour |
| Now button | Title + hint "Returns the timeline to the current time" |
| Date/phase readout | Combined into one element ("Jun 24 at 3:00 PM, Medium Flood") |
| Tide chart (`TideChartView` Canvas) | Single element labelled with the current tide ("Tide 2.4 metres at Bedwell Harbour, above chart datum") |
| Phase row | Single element ("medium flood tide. 0.4 knots at crosshair.") |
| Crosshair | `.accessibilityHidden(true)` — decorative |

Not automatable from CLI — verify with the Accessibility Inspector or an
XCUITest before shipping (e.g. assert the "Forecast time" element is adjustable).

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

### Platform notes

- `@Observable` (used via `MapViewModel`); GRDB over SwiftData for migration performance.
- `.ultraThinMaterial` auto-gains the Liquid Glass appearance on iOS 26 — no code change needed; watch for visual regressions there.

### Data bootstrap (before first build)

`data/` is gitignored and **not** in a fresh clone, but the post-build script
(`project.yml`) rsyncs it into the app bundle — a missing dir fails the build.
Generate it first:

- **Atlas currents** (`data/maps*`): produced by the extraction tooling in `dev/extraction/`.
- **Tide predictions** (`data/tides/tides_2026.json`): run `python3 dev/tides/fetch_tides.py`
  (needs network — pulls NOAA + CHS). Re-curate the station set first with
  `dev/tides/curate_stations.py` only if changing coverage/year.

If `data/tides/` is absent the app builds with no tide data and the chart shows
its "Tide data unavailable" placeholder.

---

## 8. Settings & User Preferences

User preferences live in `AppSettings` (`Models/AppSettings.swift`), an
`@Observable` store persisted to `UserDefaults` and injected through the SwiftUI
environment — the same pattern as `MapViewModel`, so both SwiftUI views and the
`MapLibreView` representable react without prop-drilling.

| Preference | Type | Default | Affects |
|-----------|------|---------|---------|
| `speedUnit` | knots / km·h / m·s | knots | Phase panel speed readout + VoiceOver |
| `heightUnit` | metres / feet | metres | Tide chart cursor, y-axis, VoiceOver |
| `showCrosshair` | Bool | on | `CrosshairView` visibility |
| `appearance` | system / light / dark | system | `.preferredColorScheme` on the root → drives the full Day/Night theme (§2.3) |

**Canonical units never change in storage.** Currents are stored in knots
(`CurrentVector.speedKnots`) and tide heights in metres (station datum);
conversion happens only at the readout via `AppSettings.formatSpeed/​formatHeight`
or the `SpeedUnit`/`HeightUnit` `value(from:)` helpers. Never persist a converted
value — round-tripping loses precision.

**Appearance default is `.system`.** Because `.preferredColorScheme` sets the
`colorScheme` environment that every surface observes, the override switches the
**whole** Day/Night theme — basemap, panels, chart/tape ink, crosshair, and the
per-theme current-arrow ramp (§2.3) — not just the chrome.

---

## 9. Open Design Backlog

**Resolved in the settings/HIG-audit pass:**
- ✅ Settings + About surface (§5.6) — data-source attribution now in-app
- ✅ Non-standard `✛` speed suffix → `scope` SF Symbol (§5.1)
- ✅ Unit preferences (speed / height) with a unit-agnostic tide-chart axis

| Priority | Item | Notes |
|----------|------|-------|
| High | Real nautical basemap | CARTO raster (Day/Night) is a placeholder. Need PMTiles + a proper chart style with depth/seamark data. |
| Medium | Speed legend | Users need a legend to understand the 5-color current scale (per-theme — see `currentSpeedRamp`) |
| Low | VoiceOver audit | Labels are in place (§6.2); verify reading order + adjustable tape on-device with the Accessibility Inspector |
| Low | Haptic feedback | Add impact feedback to tape hour-snaps and the return-to-now control |
| Low | Portrait layout | Verify timeline + phase panel + settings button don't overlap in portrait on smaller iPads |
