# iOS Production Handoff — Salish Sea Current Atlas

This package is everything needed to start building the **production native iOS (Swift), fully
offline iPad** app. The earlier Vite/TypeScript prototype is complete and is **not** included —
its discoveries are distilled into the spec below.

## Contents
- **`PRODUCTION_SPEC.md`** — start here. Build instructions, the chart-selection algorithm (with a
  Swift sketch), data formats, the offline-first fallback chain, rendering notes, regeneration, and
  prioritized open items.
- **`data/atlas_lookup_2026.json`** (~28 KB) — the authoritative chart-selection table. The app's
  primary input. Bundle it.
- **`data/atlas_index.json`** (~48 KB) — chart bounds + region/landmark catalog. Bundle it.
- **`data/maps/`** (~21 MB, 344 files) — current vector fields, one file per chart × region
  (`map_<1..43>_<A..H>.json`). Bundle it (optionally repacked — see spec §5.3).

## The one thing to know before reading anything else
Chart selection is a **table lookup keyed to `America/Vancouver` local hour**, not a tide
computation. See `PRODUCTION_SPEC.md` §2. The biggest unbuilt piece is a **bundled offline nautical
basemap** (§9, item 1) — decide that first.
