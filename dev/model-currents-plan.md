# Model Currents — Parallel System Plan (SalishSeaCast)

Status: **research / planning** (not started). Goal: a second current-data source
that (a) covers the whole Salish Sea grid — including the sheltered bays the
print atlas doesn't chart (Bellingham Bay, Padilla Bay, etc.) — and (b) produces
a *continuous* velocity field in time and space, suitable for the future
particle-flow animation. Fully offline.

## Why a parallel system

The bundled atlas (1.2M arrows, `data/maps*`) is a precomputed snapshot of a
harmonic tidal model at ~43–69 discrete phases, selected by an hourly lookup
table. It only charts the navigable passages, so areas like Bellingham Bay have
**no data at any tide phase** — a source-coverage limit, not a render bug. A
model layer fills those gaps and gives smooth-in-time output.

## Core idea: on-device harmonic prediction

Tidal currents = sum of harmonic constituents (M2, S2, N2, K2, K1, O1, P1, Q1 —
the same eight the atlas's Foreman-2004 model uses). The only location-specific
data is each constituent's **amplitude + phase** for the east (U) and north (V)
velocity. Bundle those; synthesize on device:

```
U(t) = Σ fᵢ · ampᵢ · cos(ωᵢ·t + (V₀+u)ᵢ − phaseᵢ)      # east
V(t) = Σ fᵢ · ampᵢ · cos(ωᵢ·t + (V₀+u)ᵢ − phaseᵢ)      # north
speed = √(U²+V²),  dir = atan2(U, V)
```

`ωᵢ` = constituent speed (known constant); `(V₀+u)ᵢ` = astronomical argument +
nodal phase (from the date); `fᵢ` = nodal amplitude factor. Pure arithmetic, any
minute, everywhere — no network. Same math family as standard tide-height
prediction (XTide/utide), extended to 2-D U/V.

## SalishSeaCast findings (researched 2026-06)

Run by UBC-MOAD. ERDDAP server: <https://salishsea.eos.ubc.ca/erddap/>

- **License: Apache 2.0** on the NEMO model results. Permits bundling a *derived*
  product (constituents we compute) in a shipping app — even commercial — with
  attribution + the NOTICE. **No blocker.**
- **Coverage:** whole Salish Sea — Juan de Fuca, Strait of Georgia, Puget Sound,
  Johnstone Strait. NEMO grid 398×898, ~500 m, curvilinear. Bellingham Bay and
  the other uncharted bays are inside the domain.
- **Currents product:** `ubcSSfDepthAvgdCurrents1h` — near-surface depth-averaged
  `VelEast5/10`, `VelNorth5/10`, hourly. Surface-ish currents = what a sailor
  wants. (The live dataset is a rolling 8-day forecast; a multi-year **hindcast**
  archive is also on ERDDAP.)
- **Catch:** they publish harmonic-analysis *tools* (`tidetools.fittit()`,
  MATLAB t_tide — <https://github.com/SalishSeaCast/docs/blob/main/tidalcurrents/tidal_current_tools.rst>),
  **not a precomputed constituent grid**. We'd derive it from a hindcast time
  series ourselves — or ask MOAD for their already-computed ellipse/constituent
  grid (they make these for their own validation).
- The atlas's own **Foreman-2004** constituents aren't openly downloadable
  (Foreman, Sutherland & Cummins 2004, *Cont. Shelf Res.* 24(18):2167) — would
  require contacting the authors.

## Pipeline (one-time dev work → thin device layer)

1. **Acquire** — pull ~1 yr (≥~6 mo with constituent inference) of hourly
   depth-averaged currents from the SalishSeaCast hindcast via ERDDAP, subset to
   the domain. Heavy one-time download; do it on a cloud box, mask to water.
2. **Analyze** — `utide`/t_tide per grid node on U and V → amp/phase per
   constituent. Compute-heavy, done once.
3. **Resample + pack** — interpolate NEMO's curvilinear grid → a **regular
   lat/lon grid** (so device lookup is a trivial bilinear), pack to a compact
   binary blob. ~1 km, water-only → ~40–60k nodes × 8 const × 4 vals →
   **~5–15 MB bundled** (vs the ~90 MB arrow DB).
4. **Predict (Swift)** — ✅ **DONE.** `SalishTides/CurrentModel/TidalHarmonics`
   (astronomical engine: Doodson equilibrium argument + Schureman nodal
   corrections for the 8 constituents) + `TidalCurrentField` (U/V synthesis +
   bilinear grid sampler → `CurrentVector`). Built/iterated in Python
   (`dev/model/tidepredict.py`), validated against NOAA Seattle tide
   predictions (**correlation 0.997**), then ported to Swift and re-validated
   to identical numbers (`dev/model/SwiftValidate`). Only the constituent grid
   (step 1–3 / UBC) is still needed; the device-side predictor is ready.
5. **Integrate** — a parallel "Model" current source feeding the *existing*
   arrow renderer; viewport → sample grid → `{lat,lon,speed,dir}`. Atlas stays
   untouched (default), model fills gaps / is a toggle.
6. **Validate** — cross-check vs the atlas in the channels (both harmonic, should
   agree); vs a NOAA current station or two (Rosario, Admiralty) for absolute
   accuracy.

## Risks / unknowns

- **Data acquisition is the gating unknown**, not the offline mechanics (small,
  well-trodden). Fastest path may be a single email to UBC-MOAD for their
  constituent grid → could collapse steps 1–2.
- Record length must separate close pairs (S2/K2, K1/P1): ~1 yr ideal, ~6 mo
  workable with inference.
- Curvilinear NEMO grid → resample offline to keep device code simple.
- Accuracy is astronomical-tide only (no wind/freshwater) — same as the atlas,
  so no regression, and it now resolves the bays.

## PoC findings (2026-06) → pivot to email-first

Ran a minimal end-to-end DIY probe (`dev/model/poc_bellingham.py`, plus grid +
mask checks). What we learned:

- **Coverage confirmed.** The NEMO grid (`ubcSSnBathymetryV21-08`, 398×898,
  lat 46.86–51.10, lon −126.40 to −121.32) covers the whole domain. A 17×17 block
  around Bellingham Bay has 115 water cells (34 in the inner bay) with real
  surface currents up to ~0.14–0.29 m/s — **the model resolves the bays the atlas
  omits.**
- **Archive is ample.** Green hindcast `ubcSSg3D{u,v}GridFields1hV21-11` is hourly
  **2007→2026 (170,784 steps)** — far more than enough for harmonic analysis.
- **DIY is impractical at scale.** ERDDAP single-point extraction from the chunked
  3-D dataset is ~20 min/point; a per-cell time-series pull over the grid is
  infeasible, and the full 3-D field is ~TB to download. Plus land-mask handling
  (our first test node was masked → all-zero).

**Decision: pivot to (a) — email UBC-MOAD** for their already-computed constituent/
ellipse grid. Draft ready at `dev/model/ubc-moad-email-draft.md`. DIY (b) stays the
documented fallback if they can't share it; the predictor + on-device pieces are
unchanged regardless of how we source the constituents.

## Sources

- SalishSeaCast ERDDAP — <https://salishsea.eos.ubc.ca/erddap/>
- Depth-averaged currents dataset (license/coverage/vars) —
  <https://salishsea.eos.ubc.ca/erddap/info/ubcSSfDepthAvgdCurrents1h/index.html>
- Tidal-current harmonic tools —
  <https://github.com/SalishSeaCast/docs/blob/main/tidalcurrents/tidal_current_tools.rst>
- Project docs / CITATION — <https://github.com/SalishSeaCast/docs>
