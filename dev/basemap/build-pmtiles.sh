#!/usr/bin/env bash
#
# Build the bundled offline basemap: a Protomaps (OpenStreetMap, ODbL) vector
# tile extract of the Salish Sea, written to data/basemap/salish.pmtiles.
#
# This is the single source of truth for the offline Standard basemap. The app
# bundles the resulting .pmtiles (copied into Resources/basemap/ by the Xcode
# "Copy Atlas & Tide Data" phase) and renders it locally via MapLibre's native
# pmtiles:// support — no network, no API key.
#
# Requirements: the `pmtiles` CLI (`brew install pmtiles`), `tile-join`
# (`brew install tippecanoe`) for the layer-strip step, and `curl`. The extract
# uses HTTP range requests against Protomaps' hosted planet build, so it
# downloads only our region (~50 MB), not the whole planet (~136 GB).
#
# Usage:  dev/basemap/build-pmtiles.sh [YYYYMMDD]
#   YYYYMMDD  Optional Protomaps daily-build date. Defaults to auto-detecting
#             the most recent available build (they are retained ~1 week).

set -euo pipefail

# --- Coverage --------------------------------------------------------------
# Outer envelope of the WebTide outer-coast current model (webtide_nepac.b1:
# lat 45.98–60.00, lon -140.06–-121.97) plus a small margin. This is the box
# the app clamps the camera to (ChartBounds.coverage) — NOT the set of tiles
# actually shipped. The extract below is clipped to a coastal REGION (see
# coastal-region.py) that follows the modelled water and drops the tile-dense
# BC interior with no current data under it; so the archive is far smaller than
# this rectangle implies while still covering every coast the arrows reach.
BBOX="-140.1,45.9,-121.9,60.05"   # min_lon,min_lat,max_lon,max_lat
# z0–12 vector tiles; MapLibre overzooms to the app's z14 ceiling (vector
# geometry/labels stay crisp). Bump to 13/14 for sharper-but-larger archives
# (z13 ≈ 114 MB, z14 ≈ 237 MB) if a denser harbour detail is ever needed.
MAXZOOM=12
# Layers dropped from the Protomaps schema — it's a boating app, so roads /
# buildings / points-of-interest are noise (and look wrong over water). We keep
# earth, water, landcover, landuse (land topo), places and boundaries.
EXCLUDE_LAYERS=(roads buildings pois)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${REPO_ROOT}/data/basemap/salish.pmtiles"

# --- Keep the app's camera clamp in sync -----------------------------------
# The app constrains the map to this exact extent (ChartBounds.coverage). If
# BBOX changes and the constant doesn't, the app clamps to the old box and the
# mismatch is invisible — a wrong-but-plausible map rather than a build error.
# Fail loudly here instead, since this script is the only thing that moves the
# boundary. (The .pmtiles header can't be the source of truth: tile-join
# rewrites it to global bounds.)
CHART_BOUNDS="${REPO_ROOT}/SalishTides/Models/ChartBounds.swift"
IFS=',' read -r bb_lon_min bb_lat_min bb_lon_max bb_lat_max <<< "$BBOX"
# Isolate the `coverage` declaration first (it spans two lines) so other
# ChartBounds literals in the file — cameraPan, zoomFloorFrame — don't get
# scooped up by the number extraction.
cov_block=$(sed -n '/static let coverage = ChartBounds(/,/)/p' "$CHART_BOUNDS")
swift_bounds=$(printf '%s\n' "$cov_block" | sed -n 's/.*lat_min: *\([-0-9.]*\), *lat_max: *\([-0-9.]*\),.*/\1,\2/p;s/.*lon_min: *\([-0-9.]*\), *lon_max: *\([-0-9.]*\)).*/\1,\2/p' | tr -d '\n')
expected="${bb_lat_min},${bb_lat_max}${bb_lon_min},${bb_lon_max}"
if [[ "$swift_bounds" != "$expected" ]]; then
  echo "error: BBOX and ChartBounds.coverage disagree." >&2
  echo "  build-pmtiles.sh BBOX : lat ${bb_lat_min}..${bb_lat_max}, lon ${bb_lon_min}..${bb_lon_max}" >&2
  echo "  ChartBounds.coverage  : ${swift_bounds:-<not found>}" >&2
  echo "  Update 'static let coverage' in ${CHART_BOUNDS#$REPO_ROOT/} to match, then re-run." >&2
  exit 1
fi

command -v pmtiles   >/dev/null || { echo "error: pmtiles CLI not found — 'brew install pmtiles'" >&2; exit 1; }
command -v tile-join >/dev/null || { echo "error: tile-join not found — 'brew install tippecanoe'" >&2; exit 1; }
command -v curl      >/dev/null || { echo "error: curl not found (needed to detect the latest Protomaps build)" >&2; exit 1; }

# --- Resolve a valid Protomaps build date ---------------------------------
build_date="${1:-}"
if [[ -z "$build_date" ]]; then
  echo "Detecting latest Protomaps build…"
  for i in $(seq 0 8); do
    d=$(date -v-"${i}"d +%Y%m%d 2>/dev/null || date -d "-${i} day" +%Y%m%d)
    if curl -sf -r 0-0 -o /dev/null "https://build.protomaps.com/${d}.pmtiles"; then
      build_date="$d"; break
    fi
  done
  [[ -n "$build_date" ]] || { echo "error: no Protomaps build found in the last 8 days" >&2; exit 1; }
fi

SRC="https://build.protomaps.com/${build_date}.pmtiles"
echo "Source : $SRC"
echo "BBox   : $BBOX   maxzoom=$MAXZOOM"
echo "Output : $OUT"

mkdir -p "$(dirname "$OUT")"

# 1. Region/zoom subset from the hosted planet (range requests, ~tens of MB).
#    Use a temp dir so the file keeps its .pmtiles extension (tile-join detects
#    the format from it) without orphaning a stray mktemp file.
TMP_DIR="$(mktemp -d -t salish-basemap)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1a. Build the coastal extract region from the current models' water footprints
#     so we ship coast/ocean tiles but not the BC interior. Falls back to the
#     bbox if its deps are missing (still correct, just larger).
REGION="$TMP_DIR/region.geojson"
region_arg=(--bbox="$BBOX")
if python3 -c "import numpy, shapely" 2>/dev/null \
   && python3 "$(dirname "$0")/coastal-region.py" "$REGION"; then
  region_arg=(--region="$REGION")
  echo "Extract region: coastal (from current-model footprints)"
else
  echo "warning: numpy/shapely missing — extracting the full bbox (larger archive)" >&2
fi

RAW="$TMP_DIR/raw.pmtiles"
pmtiles extract "$SRC" "$RAW" "${region_arg[@]}" --maxzoom="$MAXZOOM"

# 2. Strip the unwanted layers (tile-join re-tiles; pmtiles extract can't drop
#    layers). -L excludes a layer.
exclude_args=()
for layer in "${EXCLUDE_LAYERS[@]}"; do exclude_args+=(-L "$layer"); done
JOINED="$TMP_DIR/joined.pmtiles"
tile-join -f -pk -o "$JOINED" "${exclude_args[@]}" "$RAW"

# 3. Rewrite `earth` as the exact complement of the ocean polygons. The app's
#    styles draw land ABOVE the ocean fill (the current-particle layer sits
#    between them), which is only correct when earth ≡ ¬ocean; the upstream
#    generalized earth fills whole channels at z8–10 when drawn on top. See
#    derive-earth.py for the full story and its python deps.
python3 -c "import pmtiles, mapbox_vector_tile, shapely" 2>/dev/null || {
  echo "error: python deps missing — 'pip3 install pmtiles mapbox-vector-tile shapely'" >&2; exit 1; }
python3 "$(dirname "$0")/derive-earth.py" "$JOINED" "$OUT"

echo
echo "Done. $(du -h "$OUT" | cut -f1) → $OUT  (dropped: ${EXCLUDE_LAYERS[*]}; earth = ¬ocean)"
pmtiles show "$OUT" | grep -E "tile type|min zoom|max zoom"
