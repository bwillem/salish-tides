# Changelog

All notable changes to Salish Tides are recorded here. Versions follow
[semantic versioning](https://semver.org); dates are the release date in the
Salish Sea (America/Vancouver). The newest release is first.

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
