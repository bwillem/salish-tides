#!/usr/bin/env python3
"""B1 packer — resample the curvilinear NEMO constituent grid onto a regular
lat/lon mesh and write a compact binary the app loads directly.

TidalCurrentField (Swift) samples a REGULAR mesh: node index = row*cols+col,
lat = lat0+row*dLat, lon = lon0+col*dLon, bilinear at runtime. Our analysis
grid is on NEMO's curvilinear gridY/gridX (irregular lat/lon), so we nearest-
assign each mesh cell to the closest NEMO water node within ~1 cell. Nearest
(not interpolate) avoids phase-wrap issues; the runtime bilinear interpolates
predicted VELOCITIES, which is safe.

Binary format: SCTF1 — the full byte layout is documented (and read/written)
in dev/model/sctf1.py, the shared module all .b1 tooling goes through. The
Swift decoder in OfflineCurrentModel.swift must stay in lockstep with it.
"""
import json, math, os, sys, argparse
import numpy as np
from scipy.spatial import cKDTree

# Anchor every path on this file's location so the script runs from anywhere,
# not just the repo root.
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import sctf1
from tidepredict import CONSTITUENTS

# Mesh resolution is a knob: 1.0 km matches the stride-2 NEMO whole-domain
# slice (the live tier's coarse fallback), 0.5 km matches NEMO's native cell
# and the live tier's nav-zoom native window — pack at 0.5 so offline renders
# at the same density live does where a boater is actually looking. The source
# analysis grid is at native ~0.5 km, so a finer mesh recovers real detail, not
# interpolation. The Swift decoder is header-driven (reads rows/cols/dLat/dLon),
# so a finer mesh needs NO app change.
#
# Run-only CLI script (no importable API): guard against an accidental
# `import b1_pack_grid`, which would otherwise parse the importer's argv and
# pack/write files as an import side effect.
if __name__ != "__main__":
    raise ImportError("b1_pack_grid.py is a CLI script — run it, don't import it")

ap = argparse.ArgumentParser()
ap.add_argument("--km", type=float, default=1.0,
                help="mesh spacing in km (1.0 = legacy stride-2, 0.5 = native)")
ap.add_argument("--src", default=os.path.join(HERE, "b1_grid_full.json"))
ap.add_argument("--out", default=os.path.join(REPO, "SalishTides", "Resources",
                                              "current_model.b1"))
ap.add_argument("--allow-any-frame", action="store_true",
                help="skip the geographic-frame guard (prototyping only)")
A = ap.parse_args()
KM = A.km
SRC = A.src
# The shipped asset lives with the app's other bundled resources, NOT under
# dev/ — dev/model is scratch tooling with gitignored siblings, and a
# load-bearing asset there fails only at runtime (a failed decode simply means
# no offline currents for that model's domain). Meta stays here beside the
# pipeline.
OUT = A.out
# Meta tracks the output basename so a scratch/proto pack can't clobber the
# shipped asset's meta (default OUT -> dev/model/current_model.b1.meta.json).
META = os.path.join(HERE, os.path.basename(OUT) + ".meta.json")
K = list(CONSTITUENTS)                       # constituent order in the file

g = json.load(open(SRC))
# The app renders the packed components as geographic east/north; packing a
# grid-frame (unrotated) solve skews every direction ~29°. b1_analyze_full's
# merge step rotates and tags the frame — refuse anything else.
assert A.allow_any_frame or g.get("frame") == "geographic", (
    "b1_grid_full.json is not in the geographic frame — re-run "
    "dev/model/b1_analyze_full.py (its merge step rotates grid-frame u/v).")
nodes = g["nodes"]

# The Swift decoder drops non-finite nodes defensively, but a NaN coefficient
# here means the fit went degenerate — fail the pack, don't ship it.
for n in nodes:
    vals = [n["uMean"], n["vMean"]] + [x for cc in n["c"].values()
                                       for x in (cc["uAmp"], cc["uPhase"],
                                                 cc["vAmp"], cc["vPhase"])]
    assert np.isfinite(vals).all(), f"non-finite coefficient at node {n['gridY']},{n['gridX']}"
lat = np.array([n["lat"] for n in nodes])
lon = np.array([n["lon"] for n in nodes])
print(f"source: {len(nodes)} curvilinear water nodes")
print(f"  lat {lat.min():.3f}..{lat.max():.3f}  lon {lon.min():.3f}..{lon.max():.3f}")

# --- regular mesh at the requested spacing (default ~1 km) ------------------
latmid = float(np.median(lat))
DLAT = KM / 111.0                             # KM km in latitude
DLON = KM / (111.0 * math.cos(math.radians(latmid)))   # KM km in longitude
lat0 = math.floor(lat.min() / DLAT) * DLAT
lon0 = math.floor(lon.min() / DLON) * DLON
rows = int(math.ceil((lat.max() - lat0) / DLAT)) + 1
cols = int(math.ceil((lon.max() - lon0) / DLON)) + 1
assert rows <= 65535 and cols <= 65535, "mesh exceeds u16 header fields"
print(f"mesh @ {KM:.2f} km: {rows}x{cols} = {rows*cols} cells, "
      f"dLat {DLAT:.5f} dLon {DLON:.5f}")

# KD-tree in km-scaled coords so 'nearest' is true distance, not raw degrees.
def scale(la, lo):
    return np.column_stack([(la - latmid) * 111.0,
                            (lo - lon0) * 111.0 * math.cos(math.radians(latmid))])
tree = cKDTree(scale(lat, lon))
# Assign a mesh cell to a NEMO node only if one is within 1.2 mesh-widths — the
# same 1.2 km the legacy 1 km pack used, now scaled with KM so the KM=1.0
# default reproduces it exactly, while a 0.5 km mesh tightens to 0.6 km and
# keeps a crisp coastline instead of pulling water inland.
THRESH_KM = KM * 1.2

# mesh cell centers
mr, mc = np.meshgrid(np.arange(rows), np.arange(cols), indexing="ij")
mlat = lat0 + mr.ravel() * DLAT
mlon = lon0 + mc.ravel() * DLON
dist, idx = tree.query(scale(mlat, mlon))
assigned = dist < THRESH_KM
src_idx = np.where(assigned, idx, -1).reshape(rows, cols)
print(f"assigned {assigned.sum()} / {rows*cols} mesh cells to a NEMO node "
      f"({100*assigned.sum()/(rows*cols):.0f}% water)")

# --- write binary (SCTF1, via the shared module) ----------------------------
flat = src_idx.ravel()
present = flat >= 0
coeffs = np.empty((int(present.sum()), 2 + 4 * len(K)), np.float32)
for j, si in enumerate(flat[present]):        # present nodes, row-major order
    n = nodes[si]; c = n["c"]
    row = [n["uMean"], n["vMean"]]
    for name in K:
        cc = c[name]
        row += [cc["uAmp"], cc["uPhase"], cc["vAmp"], cc["vPhase"]]
    coeffs[j] = row
npres = len(coeffs)
sz = sctf1.write(OUT, sctf1.Grid(rows, cols, lat0, lon0, DLAT, DLON,
                                 K, present, coeffs))
print(f"wrote {OUT}  ({sz/1e6:.2f} MB, {npres} nodes, {len(K)} constituents)")

# --- validation: re-read the WRITTEN FILE and compare to the SOURCE ---------
# A packing bug (node assignment, node order, field order) must fail here, not
# ship — so this parses current_model.b1 from disk via sctf1.read and checks
# random cells against the source JSON values. (The truly independent decoder
# is the Swift one in OfflineCurrentModel.swift, exercised by the app tests.)
g2 = sctf1.read(OUT)
assert (g2.rows, g2.cols, g2.names) == (rows, cols, K), "header mismatch on re-read"
# node ordinal = number of set presence bits before this cell
ordinal = np.cumsum(present) - 1
import random
random.seed(0)
present_cells = [(r, c) for r in range(rows) for c in range(cols) if src_idx[r, c] >= 0]
maxerr = 0.0
for r, c in random.sample(present_cells, 200):
    i = r * cols + c
    assert g2.present[i], "presence bit mismatch"
    vals = g2.coeffs[int(ordinal[i])]
    n = nodes[src_idx[r, c]]
    want = [n["uMean"], n["vMean"]] + [x for nm in K for x in
            (n["c"][nm]["uAmp"], n["c"][nm]["uPhase"],
             n["c"][nm]["vAmp"], n["c"][nm]["vPhase"])]
    maxerr = max(maxerr, max(abs(a - b) for a, b in zip(vals, want)))
assert maxerr < 1e-3, f"re-read mismatch: {maxerr}"
print(f"self-check: re-read 200 cells from {OUT}, all fields match "
      f"(max float32 err {maxerr:.2e})")
json.dump({"rows": rows, "cols": cols, "lat0": lat0, "lon0": lon0,
           "dLat": DLAT, "dLon": DLON, "constituents": K, "nodes": npres,
           "frame": "geographic", "bytes": sz}, open(META, "w"), indent=2)
print(f"meta -> {META}")
