#!/usr/bin/env bash
#
# Fetch the glyph PBFs the Standard basemap's label layers need, into
# data/basemap/glyphs/ (bundled into the app alongside the tile archive by the
# same copy phase). One fontstack, full Unicode range set (~7 MB) — regional
# names include IPA and Coast Salish characters, so partial range sets are a
# trap. Source: Protomaps' own hosted style assets (OFL-licensed Noto Sans).
#
# Usage:  dev/basemap/fetch-glyphs.sh

set -euo pipefail

FONT="Noto Sans Regular"
REPO="https://github.com/protomaps/basemaps-assets"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${REPO_ROOT}/data/basemap/glyphs/${FONT}"

TMP_DIR="$(mktemp -d -t salish-glyphs)"
trap 'rm -rf "$TMP_DIR"' EXIT

git clone --quiet --depth 1 --filter=blob:none --sparse "$REPO" "$TMP_DIR/assets"
git -C "$TMP_DIR/assets" sparse-checkout set "fonts/${FONT}"

mkdir -p "$DEST"
cp "$TMP_DIR/assets/fonts/${FONT}/"*.pbf "$DEST/"

echo "Done. $(ls "$DEST" | wc -l | tr -d ' ') ranges → $DEST"
