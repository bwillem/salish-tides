# Salish Tides — Design System

Living design reference for the Salish Tides iOS/iPadOS app.
**Update this document whenever a design decision is made or a token value changes.**

> Tokens, colours, and component anatomy below are reconciled against the code
> (`DesignTokens.swift` and the view files) as the source of truth. When code and
> this doc disagree, the code wins — fix the doc.

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

All colors live in `SalishTides/Design/DesignTokens.swift` as `Color` / `UIColor`
extensions. **Never use hex literals or `Color(red:green:blue:)` calls outside of
`DesignTokens.swift`.**

The palette is deliberately built from **system colors** wherever possible: they
carry their own light / dark / increased-contrast variants, so brand chrome tracks
the platform the way Apple's own apps do. Only true *surfaces* and the one
hand-tuned map ramp bucket use explicit values.

#### Brand & surface tokens (`Color`)
| Token | Value | Use |
|-------|-------|-----|
| `.brandAccent` | `Color.teal` (system) | Global `.tint`; every accent-chrome surface — the "Now" pill, live dot, tape "now" marker, tide-chart fill. |
| `.appBackground` | adaptive `UIColor` — deep ocean `rgb(0.10,0.22,0.36)` in Night, pale sky `rgb(0.86,0.91,0.95)` in Day | Splash / migration background. The only adaptive *surface* token. |
| `.inkSecondary` | adaptive — white @ 80% (dark) / black @ 58% (light) | Muted caption "ink" on glass cards (station name, phase, unit, status pills). Brighter than system `secondaryLabel` so it stays legible on the material per principle #1. |

#### Tide Tendency (`Color`)
| Token | Value | Meaning |
|-------|-------|---------|
| `.tideFlood` | `Color.teal` (== `brandAccent`) | Incoming tide |
| `.tideEbb` | `Color.orange` (system) | Outgoing tide |
| `Color.secondary` | system | Slack water / neutral |

Flood tracks the brand accent (teal); ebb is system orange. Both are system hues,
so they adapt across light / dark / contrast for free, and the pairing avoids
red/green colorblindness conflicts.

#### Current Speed Scale (diverging, per-theme)

Used **exclusively** for MapLibre arrow / slack-dot rendering. The single source
of truth is `UIColor.currentSpeedRamp(dark:)` — a 5-stop diverging ramp seeded
from **system colors** and resolved for the given theme, so it brightens in dark
mode and darkens in light mode automatically.

| Bucket | Speed | Source colour |
|--------|-------|---------------|
| calm | < 0.5 kn | `systemBlue` |
| light | 0.5 – 1.5 kn | `systemTeal` |
| moderate | 1.5 – 3.0 kn | `systemYellow` — **except Day**, hand-darkened to amber `rgb(0.80,0.55,0.05)` |
| strong | 3.0 – 4.5 kn | `systemOrange` |
| very strong | ≥ 4.5 kn | `systemRed` |

> **The one hand-tuned bucket:** on the pale Day basemap, `systemYellow` (the
> diverging midpoint) lacks contrast against light water, so `currentSpeedRamp`
> overrides *only* that stop to amber. Every other stop is pure system colour,
> resolved per theme. There is no separate hardcoded night/day table anymore.

> **Colorblindness note:** the blue→amber→red ramp is partially accessible (avoids
> pure red/green). The calm→light transition (blue→teal) may be hard to
> distinguish for some users; line-weight is the secondary cue (§5.4).

### 2.2 System Colors & Materials

- **Overlay backgrounds:** the **Floating Card** surface — Liquid Glass on iOS 26+,
  `.ultraThinMaterial` on iOS 17–25 (see §4.1b).
- **Text over map:** `.primary` / `.inkSecondary` — both adapt to the theme.
  Prefer these over hardcoded white.
- **Text on `.appBackground` (splash):** uses `.primary` / `.secondary`, which
  adapt because `appBackground` pairs with the system background.

### 2.3 Day / Night Themes

The app ships two full themes — **Day** (light) and **Night** (dark). It follows
the **system appearance** by default, but the persisted **Appearance** setting
defaults to **Night** (`.dark`) — see §8. Every surface adapts:

| Surface | Day (light) | Night (dark) |
|---------|-------------|--------------|
| Basemap | Bundled Protomaps vector, `standard-light.json` | Bundled Protomaps vector, `standard-dark.json` |
| Splash / migration bg | `Color.appBackground` — pale sky | `Color.appBackground` — deep ocean |
| Floating cards | Liquid Glass / `.ultraThinMaterial` (auto) | same (auto) |
| Ink (card text, chart, tape) | `.primary` / `.inkSecondary` (auto → dark ink) | `.primary` / `.inkSecondary` (auto → light ink) |
| Crosshair | `.primary` reticle + `Color(.systemBackground)` inverse halo | same, inverts automatically |
| Current arrows | `currentSpeedRamp(dark: false)` — system hues resolved light, amber-corrected mid | `currentSpeedRamp(dark: true)` — system hues resolved dark |

**Rules**
- **Never hardcode `.white`** in Canvas views — use `.primary` / `.inkSecondary`
  so the chart and tape ink flip with the theme. The `GraphicsContext` resolves
  semantic colors against the view's color scheme.
- **Adaptive colors live as one token** (`Color.appBackground` / `.inkSecondary`,
  defined with `UIColor` dynamic providers); the current-speed ramp is per-theme
  (`currentSpeedRamp`, re-evaluated whenever the style reloads).
- The basemap switches via `MapLibreView` observing `@Environment(\.colorScheme)`
  and swapping `styleURL`; vectors are re-applied on the new style.

### 2.4 Map Style (offline-first, online-enhanced)

The basemap is **offline-first, progressively enhanced**: the app works 100%
offline on the bundled vector basemap, and lights up richer imagery when a
connection exists (Starlink, dock WiFi). User-selectable in **Settings → Map
Style** (`Basemap`).

| Style | Source | Offline? | Light / Dark |
|-------|--------|----------|--------------|
| **Standard** | **Bundled Protomaps vector PMTiles** (`salish.pmtiles`) + `standard-{light,dark}.json` | **Always** (the true offline baseline) | per-theme pair |
| **Satellite** | MapTiler imagery (`satellite.json`), streams | After viewing online (ambient cache) | single (imagery is theme-agnostic) |
| **Ocean** | MapTiler bathymetry (`ocean-{light,dark}.json`) | — | **hidden** (`Basemap.isAvailable == false`) — implemented but withheld until it gets its own legible current-arrow palette |

**Key mechanics:**
- **Style JSONs are bundled** in `Resources/styles/` (tiny text) and resolved by
  `MapStyleLoader`, which fills placeholders at load time and writes a temp file
  MapLibre loads:
  - `{{LOCAL_TILES}}` → a `pmtiles://` (vector) / `mbtiles://` (raster) URL for the
    style's bundled archive. `Basemap.bundledArchive` is the single switch that
    decides which style ships offline — give a style an archive and it needs no
    network; leave it `nil` and it streams.
  - `{{MAPTILER_KEY}}` → the MapTiler key for online styles. **Never committed** —
    it lives in the gitignored `Config/Secrets.xcconfig`. No key → network styles
    are disabled in the picker ("Online only" / "Unavailable").
  - `{{LOCAL_GLYPHS}}` → bundled label fonts (`basemap/glyphs/`). If glyphs are
    absent (a build that never ran `dev/basemap/fetch-glyphs.sh`), the loader
    strips symbol layers rather than fail the style.
- **Fallback chain** (`MapStyleLoader.styleURL`): the requested style → **Standard**
  → a flat water-coloured style with no dependencies. The map is never blank, even
  on a checkout that hasn't built the PMTiles archive.
- **Light + dark are bundled together** so a Day→Night flip works offline.
- **Streaming styles cache automatically** via MapLibre's ambient cache (raised to
  **256 MB** in `MapLibreView`). Tiles are cached as you view them online — no
  explicit download/progress.
- **The map never swaps basemaps on connectivity change** — the selected style
  stays, cached tiles keep serving, and the rest streams back once online. The
  "Offline" pill (§ContentView) is the only signal; it just notes new imagery is
  paused.
- **Reachability** (`NetworkMonitor`, `NWPathMonitor`) gates the picker via
  `AppSettings.isSelectable`: a network style is selectable only when online *and*
  the build carries a MapTiler key.

> The old CARTO-raster placeholder is gone: Standard now ships a real bundled
> vector basemap (Protomaps / © OpenStreetMap, ODbL). Depth contours and seamark
> data are the remaining chart-quality gap (§9).

---

## 3. Typography

Named styles live in `DesignTokens.swift` as `Font` extensions. All use SF Pro,
or SF Mono where digits must align.

| Token | Base style | Weight / trait | Role |
|-------|-----------|----------------|------|
| `.stDisplay` | `.largeTitle` | Bold | Splash / hero headline |
| `.stReadout` | `.title` | Bold + monospacedDigit | **Hero** crosshair current-speed value |
| `.stReadoutUnit` | `.callout` | Medium | Unit ("kn") beside the readout |
| `.stPhase` | `.subheadline` | Regular | Tide phase label (defined; general phase text) |
| `.stClock` | `.headline` | monospacedDigit | Timeline date/time readout |
| `.stCaption` | `.caption` | **monospaced** | Station name, phase line, status-pill labels |

**Design rationale:**
- All digit-bearing labels use `.monospacedDigit()` so layout doesn't shift as
  numbers change during scrubbing.
- SF Pro / SF Mono only — optimized for iPad legibility, respect Dynamic Type, and
  add no bundle weight.

**Dynamic Type:** all `Font` tokens use semantic styles (`.title`, `.headline`,
`.caption`, …) which scale with the user's text-size preference. Do not use
`.system(size: 14)` for body text — fixed sizes opt out of Dynamic Type. (The tape
and chart Canvas draw fixed 9 pt tick labels, which is acceptable for dense
axis ticks.)

---

## 4. Spacing & Layout

### 4.1 Spacing Scale

From `Spacing` enum in `DesignTokens.swift` (4 pt base grid):

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

From the `Radius` enum. Card-level surfaces use the **continuous** (squircle) curve.

| Token | Value | Common use |
|-------|-------|-----------|
| `Radius.sm` | 8 pt | Small controls, inner chips |
| `Radius.md` | 12 pt | Buttons, secondary surfaces |
| `Radius.lg` | 16 pt | Settings / compass / locate buttons |
| `Radius.xl` | 28 pt | **Floating glass cards** (phase panel, timeline bar) |
| `Radius.pill` | 999 | Capsule-equivalent rounded rects (status pills) |

### 4.1b Elevation & The Floating Card

The single surface treatment for every floating overlay, defined once as the
`.floatingCard(cornerRadius:)` view modifier — **do not re-derive it per view**.

- **iOS 26+:** native `.glassEffect(.regular, in: shape)` — Liquid Glass supplies
  translucency, edge highlight, and shadow as one adaptive material, clipped to the
  shape.
- **iOS 17–25:** the hand-built fallback so older devices look unchanged —
  `.ultraThinMaterial`, `Radius.xl` continuous corner, a `Elevation.cardBorderColor`
  (white @ 12%, 0.5 pt) hairline, and an `Elevation.cardShadowColor` (black @ 25%,
  radius 12, y-offset 4) drop shadow, content clipped to the shape.

```swift
SomeContent()
    .frame(width: 248)   // size first
    .floatingCard()      // then apply the surface
```

**Why a shared modifier:** it keeps the phase panel, speed card, timeline bar, and
corner buttons a single visual system, and lets the whole app adopt Liquid Glass
by touching one function.

### 4.2 iPad Layout Grid

- **Safe area:** respect all four safe areas (status bar, home indicator, sidebars).
- **Screen edge margin:** `Spacing.lg` (16 pt) minimum from any safe-area edge.
- **Map chrome budget:** timeline bar + phase panel together should not exceed ~15%
  of vertical screen height on the smallest supported iPad.

### 4.3 Touch Targets

**Minimum:** 44×44 pt (Apple HIG). **Recommended for gloved/outdoor use:** 48×48 pt.
The corner buttons (settings, compass, locate) are fixed 44×44 pt. The time tape is
36 pt tall but spans the full card width, so its drag target is large.

### 4.4 Overlay Placement

Overlays are **floating cards** (§4.1b), inset from the screen edges with the map
visible around and beneath them.

```
┌──────────────────────────────────────────────────────────────┐
│  [gear]                                ╭────────────────╮    │  ← top-right: tide/phase card
│  [compass?]              MAP           │  tide chart    │    │     (safe area + 8pt)
│  [locate]              (full bleed)    │  station·phase │    │
│                         [crosshair]    ╰────────────────╯    │
│                                        ╭────────────────╮    │  ← speed card (its own card)
│                                        │  ➤ X.X kn      │    │
│                                        ╰────────────────╯    │
│      [Offline]                          [Offline model]      │  ← status pills row
│        ╭──────────────────────────────────────────────╮      │  ← timeline card, inset 16pt
│        │            Jun 24, 15:00  ⌄        [Now]       │      │
│        │  ·····│····· (time tape) ·····                 │      │
│        ╰──────────────────────────────────────────────╯      │
│  [home indicator]                                            │
└──────────────────────────────────────────────────────────────┘
```

---

## 5. Component Anatomy

### 5.1 Tide/Phase Card + Speed Card (top-right)

The upper-right cluster is **two stacked floating cards**, not one:

**A. `PhaseIndicatorView`** — tide chart + its phase state. Fixed `width: 248`,
`Spacing.md` inner padding.
```
╭──────────────────────────────╮
│  [TideChartView — 108 pt]     │  ← curve + cursor height, station a11y label
│  Station Name                 │  ← .stCaption / .inkSecondary, inset to plot edge
│  ↑ Small Flood                │  ← text arrow (↑ flood / ↓ ebb) + phase, no colour
╰──────────────────────────────╯
```
Station name and phase are left-aligned and inset by `TideChartView.plotLeftInset`
(26 pt) so they line up under the curve. Datum and any "Live" flag are omitted here
(the chart's a11y label and the Online-mode badge carry them). Long station names
truncate; the name is normalised (first comma-segment, Title-Cased) by
`stationDisplayName`.

**B. `CurrentSpeedView`** — the crosshair speed in its **own** compact card below.
```
╭──────────────────────╮
│  ➤  0.3 kn            │  ← compass needle (direction) + value + unit
╰──────────────────────╯
```
- The **speed is the primary at-a-glance datum** — value in `.stReadout` (large
  bold mono), unit in `.stReadoutUnit` beside it, baseline-aligned, `minimumScaleFactor(0.6)`
  rather than wrap. Formatted per `AppSettings.speedUnit`.
- The leading glyph is a **compass needle** (`location.north.fill`, red) rotated to
  the current's flow direction at the crosshair (`vm.crosshairDirection`). When
  there's a speed but no direction it falls back to the `scope` reticle glyph.
- **Crosshair on land / off coverage:** the card shows an em dash (`—`).
- **No selection:** both cards are hidden (`vm.currentSelection != nil`).
- **Tide data unavailable:** the chart shows its placeholder + a11y "Data unavailable".

### 5.2 Timeline Control Bar

**Location:** bottom, floating card, inset `Spacing.lg` (16 pt) from the sides.
**Composition:** a top readout row and a time-tape row (`TapeSliderView`), spaced
`Spacing.lg`.

**Top row** — a centred, tappable date/time readout; an amber-free live dot
(`.tint`) shows when at "now"; a `chevron.down` hints the readout opens a
**graphical date-picker popover** (date only — the tape owns the hour). When
scrubbed away from now, a **"Now" pill** fades in at the right — a filled `.tint`
(teal) capsule, the unambiguous return-to-now tap target. (No phase name here — it
lives in the phase card, §5.1.)

**Bottom row — time tape** (`TapeSliderView`):
- **Range ±48 hours** (`maxHours = 48`), `pixelsPerHour = 27`. The centre cursor is
  fixed; ticks scroll past and **snap to the nearest whole hour** on release (data
  is hourly) with a short spring.
- The fixed centre cursor is `.primary` at "now" and turns **`.tideEbb` (amber)**
  when offset. The "now" tick is drawn full-height in `brandAccent`. Midnight ticks
  carry a date label + faint day divider; other 3-hour marks show the hour
  (`hourTickLabel`, 12h/24h per `AppSettings.clockFormat`).

> No haptic feedback on tape snaps or the Now pill yet (§9).

### 5.3 Crosshair

**Location:** centered in the map, non-interactive (`allowsHitTesting(false)`,
`accessibilityHidden`). Rendered by `CrosshairView` in `ContentView`.
**Design:** a Navionics-style reticle (`ReticleShape`) — a small centre "+"
(±3 pt), then four arms (22 pt) extending outward past an 8 pt gap. Drawn as two
strokes: an inverse `Color(.systemBackground)` halo (0.6 opacity, 3.5 pt) under a
`.primary` reticle (0.9 opacity, 1.5 pt).

**Why the inverse halo:** `systemBackground` is the opposite of `.primary`, so the
reticle is dark-on-light in Day and light-on-dark in Night — legible on any tile in
either theme, no per-tile tuning.

**Always present, emphasis on interaction:** the crosshair is faint at rest
(opacity 0.5) and ramps to full contrast while panning/zooming or scrubbing, easing
back a couple seconds after release (`CrosshairPresenter.isEmphasized`). There is no
"hide crosshair" setting.

### 5.3a Tide Station Marker

**What:** a map annotation marking the tide station whose predictions the phase
card is currently charting — the nearest station to the crosshair
(`MapViewModel.tideStation`). Exactly one exists at a time; when panning moves
the nearest-station result, the marker swaps to the new location with a fade.
Rendered by `TideStationAnnotationView` (a `MLNAnnotationView`,
`SalishTides/Map/`), fed by the `MapLibreView` coordinator.

**Design:** a 26 pt circular badge in `UIColor.stationMarker` — a deliberately
**muted** adaptive fill (deep ocean-teal in Night, pale slate-teal in Day; see
DesignTokens), *not* `.brandAccent`: the marker is wayfinding, not the screen's
focus, so it sinks toward the basemap rather than competing with the accent
chrome. The glyph is a `.label`-ink tendency arrow matching the phase card's —
`arrow.up` on flood, `arrow.down` on ebb, a neutral `arrow.up.and.down` before
the first selection — kept in step by the coordinator as the user scrubs. Rim
is `.label` at 40%; behind it the same muted fill pulses slowly (scale 1 → 2.2,
fade 0.5 → 0, 2.6 s ease-out loop). The glyph + shape keep it distinct from the
plain blue user-location dot. Hit target is the full 44 pt view (§4.3).

**Name pill:** the station's `stationDisplayName` in a small glass capsule
above the badge — `.ultraThinMaterial`, `.stCaption` type, the `Elevation`
hairline, status-pill insets (`Spacing.sm` / `Spacing.xs`). Hidden at rest;
revealed while either trigger holds:
- **Tap** — MapLibre annotation selection (tap the badge to show, tap open
  water to dismiss), or
- **Crosshair proximity** — the map centre sits within 30 pt of the station
  (the reticle's reach: 8 pt gap + 22 pt arm), checked per-frame while the
  camera moves.

### 5.4 Current Vector Arrows (fallback display)

Rendered by MapLibre line/circle layers, not SwiftUI. Colour comes from
`speedColorExpression(dark:)` → `UIColor.currentSpeedRamp` (§2.1).

**Line weight by speed** (`shaft` / `barb` layers):
| Speed | Shaft width | Barb width |
|-------|-------------|------------|
| < 1.5 kn | 1.4 pt | 1.1 pt |
| 1.5–3.0 kn | 1.8 pt | 1.4 pt |
| ≥ 3.0 kn | 3.0 pt | 2.5 pt |

**Slack dots:** where current is below the min-arrow threshold, a `slack` circle
layer draws faint dots (calm-bucket colour, radius 1.4, opacity 0.5) — exactly how
the print atlas marks slack — so weak areas read as "charted, slack" rather than
missing data.

**Arrow geometry:** ±25° barb spread (`±0.4363` rad), barb length = 70% of the
reference half-shaft — close to meteorological wind-barb convention.

**Role:** arrows are the *fallback* current display — used when the user picks
"Arrows" in Settings, or automatically under Reduce Motion / Low Power Mode. The
default is the animated particle layer (§5.4a). The two are mutually exclusive:
`applyCurrentStyle` toggles the shaft/barb/slack layers' visibility and the particle
layer's active state from `AppSettings.effectiveCurrentStyle`.

### 5.4a Current Particles (default)

The default display is an animated GPU particle field — flowing "comet streaks"
that convey direction and speed (`CurrentParticleLayer`, an `MLNCustomStyleLayer`
Metal subclass). Particles are the headline; arrows (§5.4) are the static fallback.

**Pipeline (30 fps, driven by a `CADisplayLink` → `setNeedsDisplay`):**
1. **Velocity field.** `MapViewModel.loadVectors` builds a `VelocityField` (Sendable:
   bbox, grid dims, interleaved east/north m/s) from the *full-resolution* vectors
   over the viewport (denser than the thinned arrow set), uploaded to an `RG32Float`
   texture (`fieldCellsAcross = 160`).
2. **Advection (compute).** Each frame a kernel advects **≈2250** particles by
   bilinearly sampling the velocity texture, reseeding any that age out, stall
   (land / slack — zero velocity means "no current"), or leave the field. Motion is
   exaggerated by `speedScale` for legibility.
3. **Streaks (render).** Each particle draws as a line from a tail (offset back along
   the flow, length ∝ speed) to a bright head, fading tail→head and over life. Drawn
   into MapLibre's render encoder with the live projection matrix, so streaks stay
   glued to the basemap through pan/zoom/rotate.

**Why streaks, not an offscreen trail buffer:** keeping everything in the map's own
render pass avoids offscreen textures, cross-queue GPU sync, and screen-space "swim"
during pans. The tradeoff is shorter tails.

**Race-free buffering:** particle buffers ping-pong; compute reads `current` → writes
`next`, render reads `current` (last frame's completed result). A 2-deep semaphore
bounds frames in flight — positions are one frame stale (invisible at 30 fps) but
drawn with the current camera, so no swim.

**Per-theme color** (`setDark`): night = cool white-blue; day = deeper saturated blue
so streaks read on the light basemap — mirroring the arrow ramp's per-theme logic.

**Performance / power:** the display link runs only while particles are selected *and*
the app is foregrounded (`setActive` / `setForeground`), so the GPU is idle in arrows
mode or in the background. 30 fps (not 60) halves the energy cost for an all-day app.

**Gotcha (recorded):** MapLibre leaves a cull mode set from its own draws; the custom
layer must call `renderEncoder.setCullMode(.none)` or its geometry is silently culled.

### 5.5 Migration / Splash Screen

`MigrationView` **matches the static launch screen exactly** so the launch image
hands off with no visible jump:
- **Background:** `Color(.systemBackground)` (adapts white/black per appearance) —
  the same surface `Info.plist`'s `UILaunchScreen` uses.
- **Wordmark:** the `LaunchLogo` image set, centred at native size (~280 pt).
- **Progress:** a bottom `ProgressView(.linear)` tinted `.primary`, 280 pt wide, with
  a "Loading charts… N%" caption.

**Note:** shows only on first launch (migration populates the SQLite caches).
Repeat launches go straight to the map.

### 5.6 Settings Button & Sheet

**Entry point** (`SettingsButton` in `ContentView`): a floating gear (`gearshape`)
in the **top-left**, using the shared `.floatingCard(cornerRadius: Radius.lg)`
surface and a fixed **44×44 pt** frame. It sits atop a top-left control cluster:
settings, a **compass** (shown only when the map is rotated, tap to reset north),
and a **locate** button.

**Sheet** (`SettingsView`): a grouped `Form` in a `NavigationStack`, with a single
confirming **Done** button.

```
Settings                                    Done
┌──────────────────────────────────────────────┐
│  UNITS                                         │
│   Current speed                      Knots ⌄   │
│   Tide height                       Metres ⌄   │
│   Clock                            24-hour ⌄   │
│  MAP & DISPLAY                                  │
│   Current        [ Particles | Arrows ]        │
│  APPEARANCE                                     │
│   [ System | Light | Dark ]                    │
│  MAP STYLE                                      │
│   Standard                              ✓      │
│   Satellite                    (Online only)   │
│  LIVE DATA                                      │
│   Disable live data                       ○──  │
│  ABOUT                                          │
│   Version                          1.0 (1)     │
│   Data Sources                            >    │
└──────────────────────────────────────────────┘
```

- **Current** and **Appearance** are segmented pickers. **Map Style** lists only
  `Basemap.isAvailable` styles; each row is tappable with a checkmark, or greyed
  with "Online only" / "Unavailable" when its network/key requirement isn't met.
- **Disable live data** flips `AppSettings.offlineOnly` — the app then behaves like
  a pure offline build (no fetching, cached live data not rendered).
- There is **no crosshair toggle** — the crosshair is always shown (§5.3).

**Data Sources** (`DataSourcesView`, pushed from About): the "not for navigation"
disclaimer, SalishSeaCast (UBC) live-forecast credit, the Salish Sea Tidal Current
Atlas, NOAA CO-OPS / CHS IWLS tide attribution, and the MapLibre / OpenStreetMap /
MapTiler basemap credits. In-app provenance is expected at App Store review for a
navigation aid.

---

## 6. Accessibility

### 6.1 Contrast

Target: **WCAG AA** minimum everywhere, **AAA (7:1)** for map-overlaid text given
outdoor use. Card text uses `.primary` / `.inkSecondary` on the glass material;
`inkSecondary` is deliberately brighter than system `secondaryLabel` to hold
legibility on the material. The moderate current bucket is the known weak spot on
the light basemap — hence the Day amber override in `currentSpeedRamp` (§2.1). Arrow
colour is decorative (redundant with line weight), so it is held to 3:1, not 4.5:1.

### 6.2 VoiceOver Labels (implemented)

| Control | Treatment |
|---------|-----------|
| Time tape (`TapeSliderView`) | Adjustable element — label "Forecast time", value reads the offset ("2 hours ahead of now" / "Now"), swipe up/down steps ±1 hour |
| Timeline readout | One element ("Now, Jun 24, 15:00" / the date-time); hint "Opens a date picker" |
| "Now" pill | Label "Return to now", hint "Returns the timeline to the current time" |
| Tide chart (`TideChartView`) | One element labelled with the current tide ("Tide 2.4 metres at Bedwell Harbour, above chart datum") |
| Phase line | One element ("Small Flood tide.") |
| Speed card (`CurrentSpeedView`) | One element leading with speed + flow direction ("0.3 kn flowing north-east at crosshair") |
| Compass / locate buttons | Labelled with hints ("Rotates the map back to north" / "Centers the map on your location") |
| Crosshair | `.accessibilityHidden(true)` — decorative |
| Tide station marker | Button — label "Tide station: Bedwell Harbour", hint "The tide chart shows predictions for this station." |

Not automatable from CLI — verify reading order + the adjustable tape on-device with
the Accessibility Inspector before shipping.

### 6.3 Dynamic Type

All body text uses semantic font styles → scales automatically. Verify at
"Accessibility Extra Extra Extra Large" that the timeline bar doesn't clip; the speed
readout already uses `minimumScaleFactor(0.6)`.

### 6.4 Reduce Motion / Low Power

The animated particles (§5.4a) and the station-marker pulse (§5.3a) are the
continuous animations. Under **Reduce Motion** *or* **Low Power Mode**,
`AppSettings.effectiveCurrentStyle` falls back to the static arrows and the
particle display link stops. `AppSettings` observes
`UIAccessibility.reduceMotionStatusDidChangeNotification` and
`NSProcessInfoPowerStateDidChange`, so the switch happens live without a relaunch.
The station marker observes the same Reduce-Motion notification and swaps its
pulse for a static faint halo (Low Power is left alone — a repeating CA
animation is far cheaper than the particle display link). Any future SwiftUI
animations should additionally gate on `@Environment(\.accessibilityReduceMotion)`.

---

## 7. iOS/iPadOS Platform Notes

### iPad-specific
- Primary target is iPad — test on iPad Pro 12.9" and iPad 10th gen.
- Support both landscape and portrait (sailors may dock in portrait).
- Stage Manager / multitasking: the map should stay functional in 2/3 split view.

### Platform notes
- State is `@Observable` stores (`MapViewModel`, `AppSettings`, …) injected via the
  SwiftUI environment. GRDB over SwiftData for migration performance.
- The Floating Card adopts native **Liquid Glass** (`.glassEffect`) on iOS 26+,
  with the `.ultraThinMaterial` fallback on iOS 17–25 (§4.1b) — watch for visual
  regressions across the boundary.

### Data bootstrap (before first build)

`data/` is gitignored and **not** in a fresh clone, but the post-build script
(`project.yml`) rsyncs it into the app bundle — a missing dir fails the build.
Generate it first:
- **Atlas currents** (`data/maps*`): the extraction tooling in `dev/extraction/`.
- **Tide predictions** (`data/tides/tides_2026.json`): `python3 dev/tides/fetch_tides.py`
  (needs network — NOAA + CHS).
- **Basemap** (`data/basemap/`): the bundled Standard PMTiles + glyphs, built by
  `dev/basemap/` (`build-pmtiles.sh`, `fetch-glyphs.sh`).

The bundled offline current model (`Resources/current_model.b1`) is committed and
needs no bootstrap.

---

## 8. Settings & User Preferences

User preferences live in `AppSettings` (`Models/AppSettings.swift`), an `@Observable`
store persisted to `UserDefaults` and injected through the environment — the same
pattern as `MapViewModel`, so SwiftUI views and the `MapLibreView` representable react
without prop-drilling.

| Preference | Type | Default | Affects |
|-----------|------|---------|---------|
| `speedUnit` | knots / km·h / m·s | knots | Speed readout + VoiceOver |
| `heightUnit` | metres / feet | metres | Tide chart cursor, axis, VoiceOver |
| `clockFormat` | 24-hour / 12-hour | **24-hour** | Timeline readout, tape ticks, chart axis |
| `currentStyle` | particles / arrows | particles | Map current rendering (see `effectiveCurrentStyle`) |
| `appearance` | system / light / dark | **dark** | `.preferredColorScheme` → the whole Day/Night theme (§2.3) |
| `basemap` | standard / satellite / (ocean) | standard | Map style (§2.4) |
| `offlineOnly` | Bool | off | Disables all live SalishSeaCast fetching + rendering |

**Canonical units never change in storage.** Currents are stored in knots
(`CurrentVector.speedKnots`), tide heights in metres (station datum). Conversion
happens only at the readout (`formatSpeed` / `formatHeight`, or `value(from:)`
helpers). Never persist a converted value — round-tripping loses precision.

**Appearance default is `.dark`.** Because `.preferredColorScheme` drives the
`colorScheme` environment every surface observes, the override switches the **whole**
Day/Night theme — basemap, panels, chart/tape ink, crosshair, and the per-theme
current ramp (§2.3). `.system` follows the device.

**`effectiveCurrentStyle`** is the render decision: particles unless the user picked
arrows *or* Reduce Motion / Low Power Mode forces the static fallback (§6.4).

**Times display in `TimeZone.salish`** (America/Vancouver) via `Calendar.salish` —
the app is region-specific, so times are "local to the water" regardless of the
device timezone. Underlying data is UTC.

---

## 9. Open Design Backlog

**Resolved:**
- ✅ Real offline basemap — Standard now ships bundled Protomaps vector PMTiles (§2.4).
- ✅ Settings + About surface with in-app data-source attribution (§5.6).
- ✅ Unit preferences (speed / height / clock) with a unit-agnostic tide-chart axis.
- ✅ Animated particle currents as the default, arrows as the accessible fallback.

| Priority | Item | Notes |
|----------|------|-------|
| High | Chart-quality basemap | The vector basemap ships, but lacks depth contours / seamark data. Needs a proper nautical chart style. |
| Medium | Re-expose the Ocean bathymetry style | Implemented but hidden (`isAvailable == false`) until it gets a legible current-arrow palette. |
| Medium | Speed legend | Users need a legend for the 5-colour current scale (`currentSpeedRamp`). |
| Low | Haptic feedback | Add impact feedback to tape hour-snaps and the return-to-now pill. |
| Low | VoiceOver audit | Labels are in place (§6.2); verify reading order + adjustable tape on-device. |
| Low | Portrait layout | Verify timeline + cards + corner buttons don't overlap in portrait on smaller iPads. |
