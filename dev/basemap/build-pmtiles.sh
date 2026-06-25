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
# Requirements: the `pmtiles` CLI (`brew install pmtiles`). The extract uses
# HTTP range requests against Protomaps' hosted planet build, so it downloads
# only our region (~50 MB), not the whole planet (~136 GB).
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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${REPO_ROOT}/data/basemap/salish.pmtiles"

command -v pmtiles >/dev/null || { echo "error: pmtiles CLI not found — 'brew install pmtiles'" >&2; exit 1; }

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
pmtiles extract "$SRC" "$OUT" --bbox="$BBOX" --maxzoom="$MAXZOOM"

echo
echo "Done. $(du -h "$OUT" | cut -f1) → $OUT"
pmtiles show "$OUT" | grep -E "tile type|bounds|min zoom|max zoom"
