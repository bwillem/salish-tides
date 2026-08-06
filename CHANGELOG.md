# Changelog

All notable changes to Salish Tides are recorded here. Versions follow
[semantic versioning](https://semver.org); dates are the release date in the
Salish Sea (America/Vancouver). The newest release is first.

## [1.2.1] - 2026-08-05

### Fixed
- Blend the narrow-pass currents smoothly into the surrounding water instead of fading out at their edges

## [1.2.0] - 2026-08-05

### Added
- Tidal currents for the narrow passes — Dodd Narrows, Seymour Narrows, Active Pass, Porlier Pass, and more. The ocean model can't resolve these tight channels, so they now use the Canadian Hydrographic Service's own predictions: the current flows through the pass on the map, and putting the crosshair over a pass (or tapping it) shows its speed now plus the next slack and maximum flood/ebb — all offline.

### Changed
- One info card for both tide and current stations: the crosshair over a pass shows that pass's currents; elsewhere it shows the nearest tide station's chart.

## [1.1.4] - 2026-08-04

### Changed
- Let the map pan to every edge of the charted area, including southern Puget Sound

## [1.1.3] - 2026-08-04

### Changed
- Grey out the current style toggle with a note while Reduce Motion is on, so it's clear arrows are shown on purpose

## [1.1.2] - 2026-08-04

### Fixed
- Show animated current particles again in Low Power Mode — the current style toggle no longer sticks on arrows

## [1.1.1] - 2026-07-30

### Changed
- Let the map pan further north, so you can centre on the currents above Vancouver Island and up Queen Charlotte Strait

## [1.1.0] - 2026-07-20

### Added
- Tap the data-source pill to see where the live currents come from

### Changed
- Keep the map inside the charted area, so panning and zooming can't wander off into blank space
- Name the live source in the pill: "SSC live model" for SalishSeaCast

### Fixed
- Disable "locate me" when your position is outside the charted area or no location is available — it used to look active but do nothing

## [1.0.2] - 2026-07-17

### Fixed
- Fixed the timeline staying in "Now" mode after you pick a date from the calendar

## [1.0.1] - 2026-07-17

### Changed
- Reorganized Settings into clearer appearance sections
- Added a first-run disclaimer noting the app is a planning aid, not for navigation

### Fixed
- The crosshair reticle now draws above tide-station markers instead of behind them
- Dialogs now match the active Day/Night theme

### Removed
- Removed the manual live-data toggle — live data now turns on automatically when
  you're online

## [1.0.0] - 2026-07-17

First public release. Salish Tides is an offline-first map of tidal currents and
tide heights for the Salish Sea — built for the helm, and designed to keep working
when you have no signal on the water.

### Added
- Full-bleed nautical map of the Salish Sea with an always-on crosshair that reads
  out current speed, direction, and tide state at any point you touch.
- Real-time surface currents from the SalishSeaCast ocean model when you're online,
  with a live "Offline" indicator when you're not.
- On-device harmonic current models so the map keeps predicting with no signal — a
  native ~500 m model across the full Salish Sea, extended up the outer coast to SE
  Alaska.
- Animated current field: GPU "comet-streak" particles advected through the flow,
  with a static-arrow style that turns on automatically under Reduce Motion or Low
  Power Mode.
- Flood / ebb indicator that learns the local flood axis from the tide curve.
- Tide heights and high/low predictions for a curated registry of Salish Sea
  stations, with a tide chart and a phase card at the nearest station.
- Scrubbable timeline covering ±48 hours, snapping to the hour, with a 12- or
  24-hour clock setting. All times display in Salish Sea local time.
- Day and Night themes that swap the whole look, including the basemap — follow the
  system appearance or override it.
- Map compass and locate controls, and optional display of your own position on the
  chart (When-In-Use location, never stored or transmitted).
- No account, no analytics, no tracking — the app collects nothing and runs fully
  offline once installed.
