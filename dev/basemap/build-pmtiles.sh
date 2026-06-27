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
# Envelope of all four atlas volumes (lat 47.07–51.05, lon -128.08–-122.20)
# plus a ~15 km margin so the basemap extends past the outermost current arrows.
BBOX="-128.23,46.92,-122.05,51.20"   # min_lon,min_lat,max_lon,max_lat
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
RAW="$TMP_DIR/raw.pmtiles"
pmtiles extract "$SRC" "$RAW" --bbox="$BBOX" --maxzoom="$MAXZOOM"

# 2. Strip the unwanted layers (tile-join re-tiles; pmtiles extract can't drop
#    layers). -L excludes a layer.
exclude_args=()
for layer in "${EXCLUDE_LAYERS[@]}"; do exclude_args+=(-L "$layer"); done
tile-join -f -pk -o "$OUT" "${exclude_args[@]}" "$RAW"

echo
echo "Done. $(du -h "$OUT" | cut -f1) → $OUT  (dropped: ${EXCLUDE_LAYERS[*]})"
pmtiles show "$OUT" | grep -E "tile type|min zoom|max zoom"
