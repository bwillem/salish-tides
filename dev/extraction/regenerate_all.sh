#!/usr/bin/env bash
# Regenerate ALL bundled atlas data from the source PDFs.
#
# WHY THIS EXISTS: data/maps* are gitignored build artifacts (the app bundles
# them at build time via the Xcode "copy data" run-script). So a change to the
# extractor (extract_vectors_fitz.py) does NOT ship until the data is
# regenerated on the machine doing the release build. Run this after any
# extractor change, or on a fresh checkout, before building for release.
#
# It also regenerates the TRACKED atlas_index*.json (viewport-culling indexes),
# which are derived from the maps -- commit any changes those produce.
#
# Usage:  dev/extraction/regenerate_all.sh
# Requires: python3 with PyMuPDF (fitz); source PDFs present in dev/pdfs/.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

declare -A OUTDIR=( [1]="data/maps" [2]="data/maps_vol2" [3]="data/maps_vol3" [4]="data/maps_vol4" )

echo "Regenerating atlas map data for all 4 volumes..."
for vol in 1 2 3 4; do
  echo "  Vol $vol -> ${OUTDIR[$vol]}"
  python3 dev/extraction/extract_vectors_fitz.py "$vol" "${OUTDIR[$vol]}"
done

echo "Regenerating viewport-culling indexes (tracked: SalishTides/Resources/atlas_index*.json)..."
python3 dev/extraction/build_atlas_index.py

echo "Done. If any tracked atlas_index*.json changed, commit them."
echo "Reminder: bump vectorKey/schemaVersion if the DATA semantics changed, so"
echo "          the app repopulates its vector DB on next launch."
