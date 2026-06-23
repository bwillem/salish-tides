# Salish Sea Current Atlas — iOS Production Spec

Build instructions and domain knowledge for the **production native iOS (Swift) app**.
This document is the authoritative handoff. A working Vite/TypeScript prototype already
proved out the data pipeline and the chart-selection logic; **that prototype is done and is
not part of the deliverable.** Everything you need to build the production app — the hard-won
discoveries and the bundleable data — is captured here and in the adjacent `data/` directory.

---

## 1. What the app does

Show **tidal current vectors** (arrows: direction + speed) for the Salish Sea on a map,
for the **current time by default**, with the ability to scrub forward/back in time.
Each moment maps to exactly **one of 43 published atlas charts**; the app draws that chart's
current field over the user's location.

**Hard requirement: fully offline.** The target user is sailing mid-water with no cell signal.
Every runtime dependency must be satisfiable from bundled resources. Anything that requires the
network is an optional enhancement that must degrade gracefully to an offline path.

Target device: **iPad** (primary), iPhone secondary. Landscape, sunlight-readable, glove-friendly
touch targets.

---

## 2. The central discovery (do not re-derive this)

**Chart selection is a table lookup, NOT a computation.**

The naive approach — predict tide *height* from harmonics, take the slope to decide flood vs.
ebb, bucket by range — **is wrong.** Tidal *current* reversal in a pass lags the local *water-level*
turn by a variable amount (often 1–3 h). Inferring current phase from height slope produces charts
that are off by hours. We burned real effort discovering this; do not repeat it.

The authoritative source is the **Salish Sea Tidal Current Atlas Calendar Lookup Tables (R.K. Dewey,
2026)**, derived from DFO *Current Atlas* Vol 3 (Crean & Huggett 1983). For **every local-clock hour
of the year**, the published table names the most representative chart (1–43). We extracted that
table to JSON. **The app's selection logic is: look up the chart for the current local hour. That's it.**

Verified against the PDF's own worked example: **Mar 20, 15:00 local → chart 3.** Also cross-checked
against live DFO Active Pass current predictions. Use these as regression anchors.

---

## 3. Chart-selection algorithm (port target)

Pure function. No network, no floating point, no harmonics in the primary path.

```
input:  a Date (an instant in time)
output: chart number 1–43, plus derived phase + flood/ebb tendency

1. Convert the instant to wall-clock components in time zone "America/Vancouver"
   (NOT the device's zone — the table is keyed to Pacific local time, DST baked in).
   Extract: year, month (1–12), day (1–31), hour (0–23).
2. If year != table.year (currently 2026) → table miss (see fallback chain, §6).
3. row = grid[String(month)][String(day)]            // 24-element array
4. chart = row[hour]
5. If chart == null  → DST spring-forward gap (Mar 8, 02:00–03:00 does not exist).
   Use row[hour-1] ?? row[hour+1]. (Only one null cell exists in the whole year.)
6. phase  = the phase bucket whose [lo,hi] range contains `chart` (see §4)
   tendency = phase name contains "flood" ? .flood : .ebb
```

### Swift sketch

```swift
struct AtlasLookupTable: Decodable {
    let year: Int
    let phases: [String: [Int]]                  // name -> [lo, hi]
    let grid: [String: [String: [Int?]]]         // month -> day -> 24 hourly charts (null = DST gap)
}

enum Tendency { case flood, ebb }

struct ChartSelection {
    let chart: Int                                // 1...43
    let phase: String                             // e.g. "large_flood"
    let tendency: Tendency
}

final class ChartSelector {
    private let table: AtlasLookupTable
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Vancouver")!   // critical
        return c
    }()

    init(table: AtlasLookupTable) { self.table = table }

    func selection(for date: Date) -> ChartSelection? {
        let p = cal.dateComponents([.year, .month, .day, .hour], from: date)
        guard p.year == table.year,
              let row = table.grid[String(p.month!)]?[String(p.day!)]
        else { return nil }                       // table miss -> fallback chain

        let h = p.hour!
        let chart = row[h] ?? (h > 0 ? row[h-1] : nil) ?? (h < 23 ? row[h+1] : nil)
        guard let c = chart else { return nil }

        for (name, lohi) in table.phases where c >= lohi[0] && c <= lohi[1] {
            return ChartSelection(chart: c, phase: name,
                                  tendency: name.contains("flood") ? .flood : .ebb)
        }
        return ChartSelection(chart: c, phase: "unknown", tendency: .flood)
    }
}
```

> Time-zone gotcha: `Calendar` with the Pacific zone is what makes this correct on a device set
> to any other zone (or with automatic time off). Do **not** use the device's local calendar.

---

## 4. The 43 charts → 6 phases

The 43 charts are six Point-Atkinson tidal phases × roughly hourly steps within each phase.
Size = peak current strength of that half-cycle.

| Phase          | Charts   | Tendency |
|----------------|----------|----------|
| `large_flood`  | 1–8      | flood    |
| `medium_flood` | 9–15     | flood    |
| `small_flood`  | 16–21    | flood    |
| `large_ebb`    | 22–29    | ebb      |
| `medium_ebb`   | 30–36    | ebb      |
| `small_ebb`    | 37–43    | ebb      |

These ranges are also embedded in `atlas_lookup_2026.json` under `phases` — **read them from the
file, don't hardcode**, so a future year's table can shift them.

---

## 5. Data artifacts (in `./data/`)

Everything here is **bundleable and offline**. Add it to the app target / an asset bundle.

### 5.1 `atlas_lookup_2026.json` (~28 KB) — the chart selector's only input
```jsonc
{
  "year": 2026,
  "timezone": "America/Vancouver",
  "mapCount": 43,
  "phases": { "large_flood": [1,8], "medium_flood": [9,15], "small_flood": [16,21],
              "large_ebb": [22,29], "medium_ebb": [30,36], "small_ebb": [37,43] },
  "grid": {
    "1": {                                  // month
      "1": [4,5,6,7,7,8,38,40,41,16,...],   // day -> 24 hourly chart numbers (index = local hour 0–23)
      ...
    },
    ...
  }
}
```
- `grid[month][day][hour]` = chart number for the local-time interval `hour..hour+1` (PST/PDT, DST baked in).
- Exactly one `null`: `grid["3"]["8"][2]` — the DST spring-forward skipped hour.
- **2026 only.** See §8 for regeneration.

### 5.2 `atlas_index.json` (~48 KB) — chart metadata + region catalog
```jsonc
{
  "metadata": { "source": "...", "author": "Richard K. Dewey", "model": "Foreman et al. 2004",
                "constituents": ["K1","O1","P1","Q1","M2","K2","N2","S2"],
                "reference_station": "Point Atkinson" },
  "regions": {
    "A": { "name": "Eastern Juan de Fuca Strait",        "landmark": "Race Passage" },
    "B": { "name": "Victoria to Port Angeles",           "landmark": "Oak Bay" },
    "C": { "name": "Northern Entrances to Puget Sound",  "landmark": "Deception Pass" },
    "D": { "name": "Western Gulf Islands",               "landmark": "Sansum Narrows" },
    "E": { "name": "Central Gulf Islands and Haro Strait","landmark": "Active Pass" },
    "F": { "name": "Eastern San Juan Islands",           "landmark": "Obstruction Pass" },
    "G": { "name": "Dodd/Gabriola/Porlier",              "landmark": "Dodd Narrows" },
    "H": { "name": "Vancouver Harbour",                  "landmark": "Vancouver Harbour" }
  },
  "index": [ { "map_number": 1, "region": "A",
               "bounds": { "lat_min":..., "lat_max":..., "lon_min":..., "lon_max":... },
               "vector_count": 441 }, ... ]
}
```
Use `bounds` to decide which region files intersect the current viewport, and to avoid loading
vector files off-screen. Use `region.name`/`landmark` for UI labels.

### 5.3 `data/maps/` (~21 MB, 344 files) — the current fields
One file per **chart × region**: `map_<1..43>_<A..H>.json`. 43 charts × 8 regions = 344 files.
Each file is a flat array of current vectors:
```jsonc
[ { "lat": 48.35346, "lon": -123.83356, "speed_ms": 0.171, "direction_deg": 110.8 }, ... ]
```
- `speed_ms` — current speed in **metres per second**. Knots = `speed_ms * 1.944`.
- `direction_deg` — compass bearing the current flows **toward** (0 = N, 90 = E, clockwise).
- A chart's full field = the union of its 8 region files. The prototype loaded and merged all 8
  per chart; in production, load only regions whose `bounds` intersect the viewport.

> Consider repacking `maps/` for iOS at build time (binary plist, per-chart concatenation,
> or a small SQLite/GRDB table keyed by `(chart, region)`) to cut 344 file opens. The JSON here
> is the source of truth; the on-device format is your choice.

---

## 6. Fallback chain (offline-first, in priority order)

The production primary path is **#1 only**. #2 and #3 are inherited from the prototype as graceful
degradation; implement them as the schedule allows, but never let them compromise offline operation.

1. **Atlas lookup table** — offline, authoritative. The whole app, essentially. §3.
2. **Live DFO IWLS current API** — *online only*. Covers dates outside the bundled table's year
   (e.g. running the 2026 build in 2027 before the table is updated). Reference station:
   **Active Pass, CHS 07527** (`stationId 63aef09f84e5432cd3b6c509`), time-series `wcp1-events`
   (slack + flood/ebb extrema). A half-cycle is bounded by two slacks with one extremum between;
   the extremum gives tendency + peak speed (→ size bucket), position between slacks gives the
   step within the phase. Endpoint: `https://api-iwls.dfo-mpo.gc.ca/api/v1`.
3. **Harmonic tide-height model** — offline, approximate, **last resort.** Point Atkinson, 8
   constituents (in `atlas_index.json metadata.constituents`; amplitudes/phases were in the
   prototype's `tideConstants.ts`). This is the *wrong-but-better-than-nothing* path from §2 — it
   infers phase from height slope. Only reach it when both the table and network have failed.

For a 2026 build shipping in 2026, the app will essentially always hit #1.

---

## 7. Rendering notes (from the prototype)

Arrow geometry, per vector:
- Convert compass bearing to vector components: `dx = sin(θ)`, `dy = cos(θ)` with `θ = direction_deg`
  in radians (compass: 0 = north/up, clockwise). Draw a line segment centered on `(lat, lon)`
  pointing toward the current, with a two-barb arrowhead at the tip (~25° spread, head ≈ 35% of shaft).
- Cull near-zero vectors (`speed_ms < ~0.02`) — they're visual noise.
- Color by speed (knots), e.g.: `<0.5` deep blue, `<1.5` light blue, `<3.0` yellow, `<4.5` orange,
  `≥4.5` red. Line width scales gently with speed.

On iOS, render as a `MKOverlay`/`MKOverlayRenderer` (if using MapKit) or a GeoJSON/line layer
(if using MapLibre Native). Re-tessellate only when the chart number changes, not on every pan.

Default camera from the prototype: center `[-123.2, 48.8]`, zoom ≈ 9.5, range zoom 7–14.

---

## 8. Regenerating the lookup table (yearly)

`atlas_lookup_2026.json` is **2026-only**. Each year, regenerate from the Dewey PDF:
- Source: *Salish Sea Tidal Current Atlas Calendar Lookup Tables* (R.K. Dewey, dewey.ca).
- The prototype's `scripts/extract_lookup_table.py` (pdfplumber) parsed the PDF grid into this exact
  JSON shape. It expects `atlas_table.pdf` in the working dir and emits the same `{year, phases,
  grid, ...}` structure. Keep that script (or a port) in the build tooling; the iOS app just bundles
  the resulting JSON. Update `year` and re-verify the Mar 20 15:00 → chart 3 anchor.
- The PDF also lists the exact representative *minute* per cell (we captured only the chart number).
  Sub-hour refinement is a future enhancement — see §9.

---

## 9. Open items / priorities for the production build

1. **OFFLINE BASEMAP — the biggest unstarted piece.** The prototype used a remote CDN basemap
   (`basemaps.cartocdn.com`) → **blank at sea**, which defeats the entire premise. Production must
   bundle offline tiles. Strongly prefer **NOAA / CHS nautical charts** (depths, hazards, aids to
   navigation) over a road basemap. Options: PMTiles + MapLibre Native iOS; or MapKit with a custom
   tile overlay; or rasterized NOAA ENC/RNC. **Decide this first — it gates the whole UX.**
2. **On-device data format.** Decide whether to ship 344 JSON files as-is or repack (§5.3).
3. **Time scrubbing UI.** Prototype had ±12 h slider + prev/next-hour + "Now". Reasonable starting point.
4. **Sub-hour refinement.** Use the PDF's representative-minute data for smoother interpolation (§8).
5. **GPS marker.** Show own position (CoreLocation). Prototype used `watchPosition`.
6. **Multi-year tables.** Bundle 2–3 years, or an in-app updater that fetches next year's table
   while in port (online), so the app keeps working past 2026 without the network at sea.

---

## 10. Provenance & accuracy

- Charts/currents: **DFO Canadian Tidal Current Atlas Vol 3** (Crean & Huggett 1983); model
  Foreman et al. 2004; 8 constituents K1 O1 P1 Q1 M2 K2 N2 S2; reference station Point Atkinson.
- Calendar lookup: **R.K. Dewey, 2026** (dewey.ca).
- These are predictions; real currents are affected by wind, weather, and freshet. The app is a
  planning aid, **not** a substitute for official charts and prudent seamanship — state this in-app.
```
