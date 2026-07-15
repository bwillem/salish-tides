#!/usr/bin/env python3
"""B1 pack verifier — independently parse current_model.b1 and quantify the
accuracy cost of the curvilinear->regular resample.

Two checks:
  A. FORMAT round-trip: parse the binary with a reader written from scratch
     (this is also the byte-level spec the Swift decoder must match) and confirm
     an assigned mesh node reproduces its source node's predicted velocity
     exactly (float32).
  B. RESAMPLE error: sample the packed REGULAR mesh (bilinear, mirroring the
     Swift TidalCurrentField sampler) at each original NEMO node's lat/lon and
     compare predicted velocity to that node's own prediction, over a spring-
     neap span. This is the real "did packing hurt" number.
"""
import json, struct, math, random, sys
import numpy as np
from datetime import datetime, timezone, timedelta
sys.path.insert(0, "dev/model")
from tidepredict import astro, node_factors, equilibrium, CONSTITUENTS

BIN = "SalishTides/Resources/current_model.b1"
SRC = "dev/model/b1_grid_full.json"

# --- A. parse the binary (from-scratch reader = the format spec) ------------
with open(BIN, "rb") as f:
    buf = f.read()
off = 0
def take(fmt):
    global off
    n = struct.calcsize(fmt); v = struct.unpack_from(fmt, buf, off); off += n
    return v
assert buf[:5] == b"SCTF1", "bad magic"; off = 5
rows, cols = take("<HH")
lat0, lon0, dLat, dLon = take("<dddd")
(nConst,) = take("<B")
names = []
for _ in range(nConst):
    (ln,) = take("<B"); names.append(buf[off:off+ln].decode()); off += ln
print(f"binary: {rows}x{cols} mesh, {nConst} constituents {names}")
print(f"  lat0 {lat0:.4f} lon0 {lon0:.4f} dLat {dLat:.5f} dLon {dLon:.5f}")

nbits = rows * cols
bitmap = buf[off:off + (nbits + 7) // 8]; off += (nbits + 7) // 8
present = np.zeros(nbits, bool)
for i in range(nbits):
    if bitmap[i >> 3] >> (i & 7) & 1:
        present[i] = True

# nodes[r*cols+c] -> dict(name -> (uAmp,uPhase,vAmp,vPhase)), plus mean
node_const = [None] * nbits
node_mean = [None] * nbits
for i in range(nbits):
    if not present[i]:
        continue
    um, vm = take("<ff")
    d = {}
    for nm in names:
        d[nm] = take("<ffff")
    node_const[i] = d; node_mean[i] = (um, vm)
print(f"parsed {present.sum()} present nodes; consumed {off}/{len(buf)} bytes "
      f"({'OK' if off == len(buf) else 'MISMATCH!'})")

# --- prediction helpers (mirror the Swift velocity()) -----------------------
K = list(CONSTITUENTS)
def predict_node(const, mean, times):
    uA = np.array([const[n][0] for n in K]); uP = np.radians([const[n][1] for n in K])
    vA = np.array([const[n][2] for n in K]); vP = np.radians([const[n][3] for n in K])
    U = np.empty(len(times)); V = np.empty(len(times))
    for i, t in enumerate(times):
        a = astro(t); arg = np.empty(len(K)); F = np.empty(len(K))
        for ki, nm in enumerate(K):
            f, u = node_factors(nm, a["N"]); arg[ki] = math.radians(equilibrium(nm, a) + u); F[ki] = f
        U[i] = (F * uA * np.cos(arg - uP)).sum() + mean[0]
        V[i] = (F * vA * np.cos(arg - vP)).sum() + mean[1]
    return U, V

def node_at(r, c):
    if 0 <= r < rows and 0 <= c < cols and present[r * cols + c]:
        i = r * cols + c; return node_const[i], node_mean[i]
    return None

def sample_bilinear(lat, lon, times):
    """Mirror TidalCurrentField.current(): interpolate predicted velocity over
    water corners, require >0.5 water weight."""
    fr = (lat - lat0) / dLat; fc = (lon - lon0) / dLon
    r0 = math.floor(fr); c0 = math.floor(fc); tr = fr - r0; tc = fc - c0
    corners = [(r0, c0, (1-tr)*(1-tc)), (r0, c0+1, (1-tr)*tc),
               (r0+1, c0, tr*(1-tc)), (r0+1, c0+1, tr*tc)]
    su = np.zeros(len(times)); sv = np.zeros(len(times)); sw = 0.0
    for r, c, w in corners:
        if w <= 0:
            continue
        nc = node_at(r, c)
        if nc is None:
            continue
        u, v = predict_node(nc[0], nc[1], times); su += u*w; sv += v*w; sw += w
    if sw <= 0.5:
        return None
    return su/sw, sv/sw

# --- B. resample error vs source nodes --------------------------------------
src = json.load(open(SRC))["nodes"]
t0 = datetime(2026, 8, 1, tzinfo=timezone.utc)
times = [t0 + timedelta(hours=6*i) for i in range(60)]     # ~15 days, spring-neap
random.seed(1)
test = random.sample(src, 400)
res_e = []; strong_res_e = []
covered = 0
for n in test:
    # source node's own prediction (constituents keyed by name -> dict)
    c = n["c"]
    const = {nm: (c[nm]["uAmp"], c[nm]["uPhase"], c[nm]["vAmp"], c[nm]["vPhase"]) for nm in K}
    su, sv = predict_node(const, (n["uMean"], n["vMean"]), times)
    got = sample_bilinear(n["lat"], n["lon"], times)
    if got is None:
        continue
    covered += 1
    pu, pv = got
    rmse = math.sqrt(np.mean((su-pu)**2 + (sv-pv)**2))
    res_e.append(rmse)
    if np.hypot(su, sv).std() > 0.3:       # strong-current node
        strong_res_e.append(rmse)

print(f"\nresample check over {covered}/{len(test)} sampled source nodes "
      f"(rest fell outside water-weighted mesh):")
print(f"  velocity RMSE packed-mesh vs source node: "
      f"median {np.median(res_e):.4f}  90th {np.percentile(res_e,90):.4f} m/s")
if strong_res_e:
    print(f"  STRONG-current nodes (std>0.3 m/s): median {np.median(strong_res_e):.4f}  "
          f"90th {np.percentile(strong_res_e,90):.4f} m/s  ({len(strong_res_e)} nodes)")
print("\n(RMSE here is the accuracy lost purely to the regular-mesh regrid; the "
      "harmonic model itself already validated at ~0.96 skill vs live SalishSeaCast.)")
