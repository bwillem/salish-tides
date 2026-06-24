# Salish Sea Atlas — Data Review Findings (2026)

Review of `salish-tides-review.zip` / `ios-production-handoff/` against the source PDFs.
Date: 2026-06-24.

## TL;DR

- **Chart numbers in all 3 lookup tables are 100% correct.** Re-extracted every cell
  independently from the calendar PDFs: **8,760 cells/volume (26,280 total), 0 disagreements**.
- **Two structural bugs were present in all 3 lookup tables — now fixed** (corrected files
  in this folder).
- **Vol 2 / Vol 4 lookup metadata was wrong** (`mapCount`, `phases`, reference station) —
  now fixed from the atlas volume PDFs.
- Map vector data (344/384/344/552 files) passes all sanity checks; known limitations in
  `DATA_EXTRACTION_REVIEW.md` confirmed, with one doc correction below.

---

## Bugs found & fixed (lookup tables)

Corrected files: `atlas_lookup_2026.json` (Vol 1&3), `atlas_lookup_vol2_2026.json`,
`atlas_lookup_vol4_2026.json` in this folder. Drop them into `ios-production-handoff/data/`.

### 1. Bogus `grid["<month>"]["0"]` rows (all 3 tables) — FIXED
Every month carried a phantom day **"0"** whose value was `[1,2,3,…,24]`. That is the PDF's
*hour-column header row* mis-captured as a date. 12 bogus rows per file (36 total). Harmless to
the documented Swift selector (it never looks up day 0) but pollutes the data and would corrupt
any "iterate all days" logic. **Removed.**

### 2. March 8 (DST spring-forward) dropped entirely (all 3 tables) — FIXED
2026-03-08 is the PST→PDT transition: 02:00 does not exist, so the PDF row has **23** chart
values, not 24. The extractor required exactly 24 and **silently dropped the whole day**.

Impact: on 2026-03-08 the Swift selector's `table.grid["3"]["8"]` lookup returns nil → table
miss → falls through to the network/harmonic fallback for the entire day. That defeats the
offline-first guarantee on that date.

Fix matches the prototype's existing convention: reconstruct 24 slots with `null` at hour index
2 (the only `null` in the year). Example (Vol 1&3):
`[40,41,null,42,11,12,13,14,15,23,24,24,25,26,27,28,29,3,4,4,5,6,7,8]`.
The 23 published values and representative times were taken from the calendar PDF; the time row
confirms the gap (…`01:07`, `03:05`… — no 02:xx). The reconstructed Vol 1&3 row is **byte-identical**
to the prototype's already-verified `public/data/atlas_lookup_2026.json`.

### 3. Vol 2 / Vol 4 metadata wrong — FIXED
Both files reported `mapCount: 43` and carried **Vol 1's 6-phase ranges**, but:

| Vol | Maps | Phases | Reference station | Worked anchor (Mar 20 15:00) |
|-----|------|--------|-------------------|------------------------------|
| 1&3 | 43   | 6 (large/medium/small × flood/ebb) | Point Atkinson | chart 3 ✓ |
| 2   | **64** | **8** (1.5/5/10/15 ft × flood/ebb) | **Seattle**     | chart 18 ✓ |
| 4   | **69** | **8** (1/2/3/4 m × flood/ebb)      | **Powell River**| chart 19 ✓ |

Consequence of the old metadata: charts 44–64 (Vol 2) and 44–68 (Vol 4) matched **no** phase
bucket, so the selector returned `phase:"unknown"` and a wrong flood/ebb tendency for them; the
1–43 charts were mislabeled with Point-Atkinson phase names that don't apply.

Correct phase ranges (from each atlas volume's Figures 5–12), now written into the files:

- **Vol 2** (Seattle): flood `1.5ft[1,6] 5ft[7,14] 10ft[15,23] 15ft[24,32]`,
  ebb `1.5ft[33,39] 5ft[40,47] 10ft[48,55] 15ft[56,64]`.
  *(Vol 2 atlas Fig 9 caption reads "flood" for maps 33–39; it is the small **ebb** — a PDF typo.
  Sequence and the other 7 captions make this unambiguous.)*
- **Vol 4** (Powell River): flood `1m[1,8] 2m[9,16] 3m[17,25] 4m[26,35]`,
  ebb `1m[36,42] 2m[43,50] 3m[51,59] 4m[60,69]`.

All anchors (chart **and** representative-minute) reproduce exactly after the fix.

### Post-fix validation
Each corrected file: 365 day-rows, every row length 24, exactly one `null` at `(3,8,2)`, all
chart values within `[1, mapCount]`, every chart 1..mapCount in exactly one phase, and a full
re-parse of the PDF vs the JSON shows **8,760 cells/volume, 0 value diffs, 0 missing days**.
Re-run anytime with `verify_lookup_vs_pdf.py` (paths at the bottom of the script).

---

## Map vector data — checks performed (no changes needed)

- **File counts exact:** Vol 1 = 344, Vol 2 = 384, Vol 3 = 344, Vol 4 = 552.
- **Speed/coords within acceptance** for every volume; no empty files.
- **Direction extraction healthy:** 0 charts (any volume) have >95% of arrows in one 90° quadrant.
- **Vol 1 calibration validates:** `extract_atlas.py --validate` → ratio 1.00 on all 8 sample
  charts (max_ext == max_exp by construction). Vol 1 `maps/` are tidal-model ground truth, not
  PDF extractions; Vols 2–4 are PDF extractions using the documented calibration.
- **`atlas_index.json` consistent:** 344 entries (Vol 1 only); every `vector_count` matches the
  actual file length (344/344).
- **Vol 4 extreme speeds confirmed plausible:** `map_13_E` (8.13 m/s) and `map_27_E` (8.35 m/s)
  fast arrows sit at 50.52–50.66°N / −125.14 to −125.25°W = the Yuculta/Dent/Gillard Rapids
  complex (~16 kn is real there).

### Documentation correction
`DATA_EXTRACTION_REVIEW.md §5` lists the 7 sparse Vol 3 Region-H files as
`map_{4,5,10,13,26,34,40}_H.json`. The actual sparse (<30 vector) files are
`map_{1,7,9,15,16,28,35}_H.json` (16–27 vectors). The count (7) and the Desolation-Sound
explanation are right; only the chart-number list is stale.

---

## Suggested improvements (not yet applied)

1. **Harden the lookup extractor** so these two bugs can't recur on the next yearly regenerate:
   - Treat a 23-value March row as the DST day → insert `null` at index 2 (don't drop the day).
   - Reject any "day" whose values are the literal sequence `1..24` (header row), or key rows by
     the parsed weekday+date instead of row position.
   - Assert post-conditions: 365 day-rows, all length 24, exactly one `null` at `(3,8,2)`,
     values within `[1, mapCount]`, full phase coverage. (This script encodes those assertions.)
2. **Add `atlas_index.json` for Vols 2–4** (bounds + vector_count per chart/region) — only Vol 1
   has one today; the viewport-culling logic in `PRODUCTION_SPEC.md §5.2` needs it per volume.
3. **Per-volume `mapCount`/`phases` are now in each file** — keep reading them from the file
   (don't hardcode 43); the selector already does.
4. **Optional prototype enhancement:** the corrected Vol 1&3 file adds a `representative_times`
   grid (the exact representative minute per cell) that the live `public/data/atlas_lookup_2026.json`
   lacks. Adopting it enables the sub-hour refinement noted in `CLAUDE.md`. The chart grid is
   otherwise identical to the current bundled file, so it's a safe superset swap.
