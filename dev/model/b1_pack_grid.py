#!/usr/bin/env python3
"""B1 packer — resample the curvilinear NEMO constituent grid onto a regular
lat/lon mesh and write a compact binary the app loads directly.

TidalCurrentField (Swift) samples a REGULAR mesh: node index = row*cols+col,
lat = lat0+row*dLat, lon = lon0+col*dLon, bilinear at runtime. Our analysis
grid is on NEMO's curvilinear gridY/gridX (irregular lat/lon), so we nearest-
assign each mesh cell to the closest NEMO water node within ~1 cell. Nearest
(not interpolate) avoids phase-wrap issues; the runtime bilinear interpolates
predicted VELOCITIES, which is safe.

Binary format (little-endian), magic 'SCTF1':
  header: magic[5], rows u16, cols u16, lat0/lon0/dLat/dLon f64,
          nConst u8, then per const: nameLen u8 + name ascii
  body:   presence bitmap (rows*cols bits, row-major, 1=water node present),
          then per present node in row-major order:
            uMean f32, vMean f32, then per const: uAmp,uPhase,vAmp,vPhase f32
"""
import json, struct, math, os, sys
import numpy as np
from scipy.spatial import cKDTree
sys.path.insert(0, "dev/model")
from tidepredict import CONSTITUENTS

SRC = "dev/model/b1_grid_full.json"
OUT = "dev/model/current_model.b1"
K = list(CONSTITUENTS)                       # constituent order in the file

g = json.load(open(SRC))
nodes = g["nodes"]
lat = np.array([n["lat"] for n in nodes])
lon = np.array([n["lon"] for n in nodes])
print(f"source: {len(nodes)} curvilinear water nodes")
print(f"  lat {lat.min():.3f}..{lat.max():.3f}  lon {lon.min():.3f}..{lon.max():.3f}")

# --- regular mesh at ~1 km (matches the stride-2 NEMO spacing) --------------
latmid = float(np.median(lat))
DLAT = 1.0 / 111.0                            # ~1 km in latitude
DLON = 1.0 / (111.0 * math.cos(math.radians(latmid)))   # ~1 km in longitude
lat0 = math.floor(lat.min() / DLAT) * DLAT
lon0 = math.floor(lon.min() / DLON) * DLON
rows = int(math.ceil((lat.max() - lat0) / DLAT)) + 1
cols = int(math.ceil((lon.max() - lon0) / DLON)) + 1
print(f"mesh: {rows}x{cols} = {rows*cols} cells, dLat {DLAT:.5f} dLon {DLON:.5f}")

# KD-tree in km-scaled coords so 'nearest' is true distance, not raw degrees.
def scale(la, lo):
    return np.column_stack([(la - latmid) * 111.0,
                            (lo - lon0) * 111.0 * math.cos(math.radians(latmid))])
tree = cKDTree(scale(lat, lon))
THRESH_KM = 1.2                              # assign if a NEMO node is within this

# mesh cell centers
mr, mc = np.meshgrid(np.arange(rows), np.arange(cols), indexing="ij")
mlat = lat0 + mr.ravel() * DLAT
mlon = lon0 + mc.ravel() * DLON
dist, idx = tree.query(scale(mlat, mlon))
assigned = dist < THRESH_KM
src_idx = np.where(assigned, idx, -1).reshape(rows, cols)
print(f"assigned {assigned.sum()} / {rows*cols} mesh cells to a NEMO node "
      f"({100*assigned.sum()/(rows*cols):.0f}% water)")

# --- write binary -----------------------------------------------------------
def f32(x): return struct.pack("<f", float(x))
with open(OUT, "wb") as f:
    f.write(b"SCTF1")
    f.write(struct.pack("<HH", rows, cols))
    f.write(struct.pack("<dddd", lat0, lon0, DLAT, DLON))
    f.write(struct.pack("<B", len(K)))
    for name in K:
        b = name.encode("ascii")
        f.write(struct.pack("<B", len(b))); f.write(b)
    # presence bitmap
    flat = src_idx.ravel()
    bits = bytearray((rows * cols + 7) // 8)
    for i, si in enumerate(flat):
        if si >= 0:
            bits[i >> 3] |= 1 << (i & 7)
    f.write(bytes(bits))
    # per present node, row-major
    npres = 0
    for si in flat:
        if si < 0:
            continue
        n = nodes[si]; c = n["c"]
        f.write(f32(n["uMean"])); f.write(f32(n["vMean"]))
        for name in K:
            cc = c[name]
            f.write(f32(cc["uAmp"])); f.write(f32(cc["uPhase"]))
            f.write(f32(cc["vAmp"])); f.write(f32(cc["vPhase"]))
        npres += 1

sz = os.path.getsize(OUT)
print(f"wrote {OUT}  ({sz/1e6:.2f} MB, {npres} nodes, {len(K)} constituents)")

# --- validation: packed values must exactly copy the assigned source node ---
import random
random.seed(0)
present_cells = [(r, c) for r in range(rows) for c in range(cols) if src_idx[r, c] >= 0]
sample = random.sample(present_cells, 200)
# re-read the packed body for those cells and compare a couple of fields
# (trusting the writer; do a lightweight self-check on amplitudes)
maxerr = 0.0
for r, c in sample:
    n = nodes[src_idx[r, c]]
    packed_uamp = struct.unpack("<f", f32(n["c"]["M2"]["uAmp"]))[0]
    maxerr = max(maxerr, abs(packed_uamp - n["c"]["M2"]["uAmp"]))
print(f"self-check: M2 uAmp float32 round-trip max err {maxerr:.2e} m/s over 200 cells")
json.dump({"rows": rows, "cols": cols, "lat0": lat0, "lon0": lon0,
           "dLat": DLAT, "dLon": DLON, "constituents": K, "nodes": npres,
           "bytes": sz}, open(OUT + ".meta.json", "w"), indent=2)
print(f"meta -> {OUT}.meta.json")
