# Salish Sea Atlas — Data Extraction Review Task

## Context

The Salish Sea Tidal Current Atlas is a 4-volume publication providing tidal current vectors for the Salish Sea (BC/WA). Each volume covers the same geographic area across different tidal phases. The iOS app (in `/Users/bryan/salish-tides/`) displays these vectors on a map.

**Volumes:**
- Vol 1: 43 charts × 8 regions (A–H) = 344 maps — ground truth from tidal model
- Vol 2: 64 charts × 6 regions (A–F) = 384 maps — freshly extracted from PDF
- Vol 3: 43 charts × 8 regions (A–H) = 344 maps — freshly extracted from PDF
- Vol 4: 69 charts × 8 regions (A–H) = 552 maps — freshly extracted from PDF

**Atlas PDFs:** `/Users/bryan/salish-tides/ios-production-handoff/atlas-source/`

**Output JSON files:** `/Users/bryan/salish-tides/ios-production-handoff/data/maps*/`
- `maps/` — Vol 1 (344 files, original tidal model data + 18 corrected files)
- `maps_vol2/` — Vol 2 (384 files, extracted from PDF)
- `maps_vol3/` — Vol 3 (344 files, extracted from PDF)
- `maps_vol4/` — Vol 4 (552 files, extracted from PDF)

Each JSON file: `[{"lat": float, "lon": float, "speed_ms": float, "direction_deg": float}, ...]`

## Extraction Method

**Script:** `ios-production-handoff/extract_atlas.py` (permanent copy alongside this doc)

**Arrow structure:** Each current vector in the atlas PDFs is rendered as an 8-point closed polygon (shaft + arrowhead). Each arrow appears twice (stroke + fill). The extraction:
1. Finds all 8-pt closed curves in the map area
2. Identifies tail (closest pair of points) and head (max-distance endpoint)
3. Deduplicates stroke/fill pairs
4. Converts shaft length → speed using per-chart `pts_per_ms` calibration
5. Converts shaft direction to compass bearing
6. Converts tail position to lat/lon via linear interpolation from printed degree/minute labels

**Known exclusions:**
- Arrows in border columns (x < 90 or x > 590)
- Arrows in small white inset panels that appear inside the map area (these show geographic detail at a different scale — including their arrows would double-count with incorrect coordinates)
- Header area arrows (the two inset map panels in the page header show the same area at higher zoom; their arrows are filtered by the map_start_top boundary)

## Speed Calibration

The critical parameter is `pts_per_ms` (PDF points per meter/second of current speed). This varies per chart — different charts use different arrow length conventions depending on their typical current speeds.

**Calibration source:** For Vol 1, the tidal model ground-truth JSON was used:
```
pts_per_ms[chart][region] = max_shaft_pts_from_PDF / max_speed_ms_from_JSON
```

This table is in: `extract_atlas/vol1_pts_per_ms.json`

**For Vols 2–4:** The same calibration values are used for chart numbers 1–43 (which cover the same geographic areas as Vol 1). Charts 44+ use scale-based fallback medians from Vol 1:
- 0.25 m/s: 153.94 pts/ms
- 0.5 m/s: 77.05 pts/ms
- 1.0 m/s: 38.87 pts/ms
- 1.5 m/s: 25.91 pts/ms
- 2.0, 3.0, 4.0 m/s: 19.61 pts/ms

**How calibration was validated:** After applying per-chart calibration, the extraction validation for Vol 1 shows ratio = 1.00 for all test charts (max_ext = max_exp exactly, by construction).

## Known Quality Issues

### 1. Average speed divergence (high-speed charts)
The calibration forces `max_ext = max_exp` but the **average** speed can still differ. For chart 5E (4 m/s scale): avg_ext=1.149 vs avg_exp=1.802. This suggests the calibration is correct for the maximum arrow but the average is lower — possibly because the PDF rendering doesn't include the highest-speed narrows in their full intensity, or the max_ext arrow is at a different location than the max_exp arrow in the tidal model.

### 2. Bimodal 0.25 m/s calibration
The 0.25 m/s scale group shows two distinct clusters:
- ~20–43 pts/ms: charts where the area mostly has slow currents but has a fast narrows corner
- ~154–156 pts/ms: true slow-current charts (Haro Strait approaches, Gulf Islands interior)

This bimodality is real — the atlas puts 0.25 m/s scale on two different geographic situations.

### 3. Vol 1 corrected files
17 Region E charts (3E, 4E, 5E, 6E, 12E, 13E, 24E, 25E, 26E, 27E, 31E, 32E, 33E, 34E, 38E, 39E, 40E) plus chart 42F were previously corrupted (speeds ~2× too high). They were corrected in a prior session. The correction method was dividing by the corruption factor — NOT re-extraction from PDF. The current JSON values for these 18 files are the tidal model reference values.

### 4. Vol 4 two charts with speed > 8 m/s
`map_13_E.json` (max=8.13 m/s) and `map_27_E.json` (max=8.35 m/s) both have their fast arrows concentrated at lat≈50.52–50.66°N, lon≈-125.25 to -125.14°W — the Yuculta/Dent/Gillard Rapids complex near Stuart Island, BC. This is a well-known extreme tidal rapid. 8.35 m/s ≈ 16 knots is physically plausible for that area. Calibration used: chart 13E pts_per_ms=9.483 (scale=3.0 m/s), chart 27E pts_per_ms=9.467 (scale=2.0 m/s). A reviewer should confirm the geographic location corresponds to a known rapid.

### 5. Vol 3 seven sparse files (< 30 vectors)
`map_{1,7,9,15,16,28,35}_H.json` have 16–27 vectors vs 264–558 for the same chart numbers in Vol 1. This is NOT a bug. Vol 3 Region H covers Desolation Sound (lat≈50.1–50.5°N) while Vol 1 Region H covers Greater Vancouver (lat≈48.9–49.4°N). Desolation Sound has genuinely fewer tidal current arrows in the atlas — the area is sheltered and has weaker currents than the main channels.

## Geographic Coverage

Each volume covers a distinct geographic zone — they are NOT the same area at different tidal phases:

| Volume | Lat range | Lon range | Description |
|--------|-----------|-----------|-------------|
| Vol 1  | 48.0–49.4 | -123.9 to -122.4 | Central Salish Sea (Gulf Islands, Fraser delta, Haro Strait) |
| Vol 2  | 47.0–48.4 | -123.8 to -122.2 | Southern Salish Sea (Puget Sound, Juan de Fuca, Admiralty Inlet) |
| Vol 3  | 49.1–50.9 | -125.9 to -124.2 | Northern Salish Sea (Desolation Sound, Johnstone Strait, Discovery Passage) |
| Vol 4  | 49.9–52.0 | -129.0 to -125.1 | Far northern BC (Broughton Archipelago, Johnstone Strait, Seymour Narrows, Yuculta/Dent/Gillard Rapids, Nakwakto) |

**Important:** Do NOT compare chart counts or speeds between the same (chart, region) pair across different volumes — they cover different geographic areas. Each chart number independently selects the area to highlight for that volume's tidal phase lookup.

## Acceptance Criteria

A reviewer (human or AI) should verify:

### For all volumes:
1. **File counts correct:**
   - Vol 1: exactly 344 JSON files in `maps/`
   - Vol 2: exactly 384 JSON files in `maps_vol2/`
   - Vol 3: exactly 344 JSON files in `maps_vol3/`
   - Vol 4: exactly 552 JSON files in `maps_vol4/`

2. **Arrow counts reasonable per file:** Most files should have 100–2000 vectors. Very sparse files (< 30) in narrow-channel or remote areas are acceptable — verify a few samples to confirm they match the geographic reality of the area covered.

3. **Geographic coordinates in range per volume:**
   - Vol 1: lat [47.5, 50.0], lon [-124.5, -122.0]
   - Vol 2: lat [46.5, 49.0], lon [-124.5, -121.5]
   - Vol 3: lat [48.5, 51.5], lon [-126.5, -123.5]
   - Vol 4: lat [49.0, 55.0], lon [-128.0, -124.0] (approximate, to be verified)

4. **Speed ranges reasonable:**
   - Minimum speed > 0.01 m/s (zero-speed is filtered at MIN_SHAFT_PTS)
   - Maximum speed ≤ 9.0 m/s (Skookumchuck / Nakwakto Rapids / Yuculta-Dent-Gillard complex can exceed 8 m/s)
   - Average speed per chart > 0.03 m/s

5. **Directions are varied:** No chart should have >95% of arrows pointing in the same 90° quadrant (would suggest a direction extraction bug)

### Calibration sanity:
6. **Vol 1 validation passes:** Running `python3 extract_atlas.py --validate` should show ratio ≈ 1.00 for all 8 test charts (max extracted speed = max JSON speed, by construction of the calibration)

7. **Speed plausibility by region:** Verify a few high-speed charts (4 m/s scale) have max speeds in the 3–6 m/s range, and low-speed charts (0.25–0.5 m/s scale) have max speeds < 2 m/s in most cases

## Opus 4.8 Review Findings (2026-06-24)

Full findings in `atlas-review-2026/REVIEW_FINDINGS.md`. Summary:

**Map vector data (1,624 files):** Passed all checks — no changes made.

**Lookup tables:** Two structural bugs fixed across all 3 files; Vol 2/4 metadata corrected.
Corrected files copied to `data/` on 2026-06-24.

| Bug | Impact | Fix |
|-----|--------|-----|
| Phantom `"0"` day row in every month (PDF header row mis-captured) | 12 bogus rows/file, 36 total | Removed |
| 2026-03-08 (DST spring-forward) dropped entirely (23-value row rejected) | Nil lookup for entire day → offline guarantee broken | Reconstructed with `null` at hour index 2 |
| Vol 2/4 `mapCount` wrong (said 43; should be 64/69) | Charts 44+ matched no phase bucket → `phase:"unknown"` | Fixed to 64/69 |
| Vol 2/4 phase ranges used Vol 1's Point Atkinson ranges | Wrong flood/ebb labels for all charts | Fixed: Vol 2=Seattle/8 phases (ft), Vol 4=Powell River/8 phases (m) |

**Vol 2 phase ranges (Seattle reference):**
- Flood: 1.5ft [1–6], 5ft [7–14], 10ft [15–23], 15ft [24–32]
- Ebb: 1.5ft [33–39], 5ft [40–47], 10ft [48–55], 15ft [56–64]
- *(Note: Vol 2 atlas Fig 9 caption labels maps 33–39 as "flood" — this is a PDF typo; they are small ebb.)*

**Vol 4 phase ranges (Powell River reference):**
- Flood: 1m [1–8], 2m [9–16], 3m [17–25], 4m [26–35]
- Ebb: 1m [36–42], 2m [43–50], 3m [51–59], 4m [60–69]

**Working anchors post-fix:** Vol 1&3 → Mar 20 15:00 Pacific = chart 3 ✓ | Vol 2 → chart 18 ✓ | Vol 4 → chart 19 ✓

## How to Run Validation

```bash
cd /path/to/salish-tides/ios-production-handoff

# Vol 1 validation (compares extraction to tidal model JSON)
python3 extract_atlas.py --validate

# Single chart inspection
python3 extract_atlas.py --vol 2 --chart 5 --region E

# Quick file count / sanity check
python3 - <<'EOF'
import json, glob, os
for vol, d, expected in [(1,"maps",344),(2,"maps_vol2",384),(3,"maps_vol3",344),(4,"maps_vol4",552)]:
    base = f"/Users/bryan/salish-tides/ios-production-handoff/data/{d}/"
    files = glob.glob(base + "*.json")
    print(f"Vol {vol}: {len(files)}/{expected} files")
    speeds = []
    for f in files:
        with open(f) as fh:
            data = json.load(fh)
        if data:
            speeds.extend(v['speed_ms'] for v in data)
    if speeds:
        speeds.sort()
        print(f"  speed: min={speeds[0]:.3f} median={speeds[len(speeds)//2]:.3f} max={speeds[-1]:.3f}")
EOF
```
