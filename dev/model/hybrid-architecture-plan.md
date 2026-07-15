# Model Currents — Hybrid Architecture (decided 2026-06)

Supersedes the pipeline in `../model-currents-plan.md` (kept for background +
SalishSeaCast findings). UBC-MOAD confirmed they have **no precomputed
constituent grid** to share, so we self-source the data. Decided direction:

> **Offline-first, two layers** — an always-available harmonic baseline we
> compute ourselves, plus a transparently-prefetched forecast cache that
> overrides it for the near term. A **thin backend we run** does all the
> heavy ERDDAP work once; devices fetch small tiles.

## Why two layers (the forecast horizon forces it)

SalishSeaCast's forecast (`ubcSSfDepthAvgdCurrents1h`: `VelEast5/VelNorth5`,
upper-5 m, hourly, 398×898 grid) only reaches **~2 days into the future**
(~5 days back + ~2 forward, updated daily). So pure fetch-and-cache caps
offline coverage at ~2 days. Tidal currents, though, are dominated by the
*astronomical* tide, which is predictable indefinitely by harmonic synthesis.
Hence:

| Layer | Horizon | Source | Accuracy |
|-------|---------|--------|----------|
| **Forecast cache** | now → ~2 days | SalishSeaCast forecast, background-prefetched | best — includes wind & freshwater |
| **Harmonic baseline** | ~2 days → ∞ | constituent grid we compute once; on-device predictor (built ✓) | astronomical tide (= print atlas, but everywhere incl. bays) |

The app serves the freshest forecast where it has it and **falls back to the
harmonic baseline beyond the cache, blended at the seam** so there's no visible
jump. Graceful degradation: the user never sees "no data" — worst case is a
slightly-less-precise but always-correct prediction.

## Components

### Backend (we run it — cheap: daily cron + static hosting + CDN)

**B1. Constituent-grid builder** *(one-time, re-run ~yearly)* — the thing that
turns the built predictor into a working baseline, and proves we can
self-source the data UBC won't give us.
- On a cloud box, pull ~1 yr of hourly **surface** currents over the grid via
  ERDDAP (2-D depth-avg fields, or surface level of the green hindcast — whole
  grid-slice per timestep, *not* the slow per-point 3-D extraction).
- Mask to water; run `utide` per water cell on U and V → amp/phase per
  constituent (8 major; more if the record supports separating S2/K2, K1/P1).
- Resample NEMO's curvilinear grid → a **regular lat/lon mesh** (device lookup
  = plain bilinear).
- Pack int16-quantized → **constituent grid blob (~5–15 MB)**. Ship bundled in
  the app (zero-infra baseline) and host for occasional updates.

**B2. Forecast tiler** *(daily cron)*
- Poll for the latest forecast field, subset to domain, decimate to ~1 km,
  water-only, quantize int16, compress.
- Tile spatially × time (hourly, ~48 future steps) → small blobs + a manifest
  (run timestamp, tile index, per-tile validity).
- Keep only the latest run (+ recent nowcast). Upload to object storage.

  **Source options** (both ~48 h horizon — evaluate for B2):
  - *SalishSeaCast forecast* (`ubcSSfDepthAvgdCurrents1h`, ERDDAP). **Pro:** same
    model family as the B1 baseline → clean blend seam. **Con:** academic ERDDAP.
  - *CIOPS-Salish Sea* (ECCC operational, 500 m, every 6 h / 48 h, MSC open data
    — GeoMet/datamart, Open Government Licence). Used by OceanConnect.
    **Pro:** official, robust distribution, permissive license. **Con:** different
    model from the SalishSeaCast baseline → possible discontinuity at the seam.
  - Leaning SalishSeaCast-for-both for seam consistency; revisit if CIOPS's
    distribution/reliability proves materially better in practice.

**B3. Hosting** — static object storage (S3 / Cloudflare R2) + CDN. Manifest
JSON + tile blobs, **no live compute** → cheap and scales. (Cron could even be a
GitHub Action committing tiles to R2.) Protects UBC's ERDDAP from N devices and
does the transform once. Attribution + Apache-2.0 NOTICE shipped in-app.

### App (offline-first)

**A1. Harmonic baseline** *(predictor DONE — `SalishTides/CurrentModel/`)* —
bundle the B1 grid; `TidalCurrentField` + `TidalHarmonics` synthesize a
`CurrentVector` anywhere/anytime with zero network. The offline-first guarantee.

**A2. Forecast prefetch + cache**
- Background top-up: `BGProcessingTask` (charging/idle) + opportunistic refresh
  on foreground/connectivity (reuse `NetworkMonitor`). Download via a background
  `URLSession` (survives suspension).
- Fetch manifest → diff vs cache → pull new tiles for the user's region (+ a
  margin). Store in the existing **GRDB** DB keyed by (tile, validTime, run);
  evict stale/past. At most once per daily run; CDN-cached.

**A3. Serving / blend** — a `CurrentProvider` that for (lat, lon, t):
1. forecast cache covers it & fresh → bilinear-in-space, linear-in-time interp;
2. else → harmonic predictor;
3. in the seam (final hours of forecast horizon) → linear blend forecast→harmonic.
Feeds the **existing arrow renderer**; atlas stays as a separate toggle/source.

**A4. UX — transparent by default.** No required UI (Spotify model). Optional
subtle "Live forecast / Predicted (offline)" badge + freshness time. Possibly a
one-tap "download currents for this trip" later.

## Validation

- Baseline: cross-check vs the atlas in the channels (both harmonic → should
  agree) and vs NOAA current stations (Admiralty Inlet, Rosario) for absolute
  accuracy. (Engine itself already validated vs NOAA tide heights, corr 0.997.)
- Forecast: verify fetched tiles reconstruct ERDDAP values; check temporal
  interpolation and the seam blend for continuity (no jump at the boundary).

## Risks / unknowns

- **Record length** for B1: ~1 yr to separate close pairs (S2/K2, K1/P1); verify
  a usable 2-D surface hindcast (else extract surface level from 3-D green —
  whole-slice per time, feasible).
- **iOS background execution is opportunistic** — can't guarantee prefetch
  timing; mitigated because the harmonic fallback means a missed top-up never
  breaks the experience.
- **Backend cost/ownership** — tiny (cron + static files) but it's infra we own.
- **UBC ERDDAP ToS / politeness** — one backend polling daily, open data,
  prominent attribution. Be a good citizen.

## Delivery phases

1. **Baseline (no infra)** — B1 builder → bundle grid → harmonic currents
   shipping. Beats the atlas, covers the bays, fully offline. *(Predictor done;
   B1 is the next concrete build.)*
2. **Forecast layer** — B2 tiler + B3 hosting; A2 prefetch/cache; A3 serve+blend.
3. **Polish** — A4 UX, NOAA-station validation, tile-size/decimation tuning,
   trip-download.

## Immediate next step

Build **B1 (constituent-grid builder)** — start with a PoC over a small water
region (e.g. the Bellingham/San Juans box): pull ~1 yr surface currents, utide
per cell, pack a mini grid, and load it into the (already-validated) predictor
to render real currents in the sim. Proves self-sourcing end-to-end and lights
up Phase 1.
