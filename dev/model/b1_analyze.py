#!/usr/bin/env python3
"""B1 PoC stage 2 — harmonic-analyze the downloaded box and pack a constituent
grid, then validate.

For every water cell: utide 1-D solve on U and on V → per-constituent
(amp, Greenwich phase) for each component (exactly the form the Swift
`TidalCurrentField.NodeConstituent` wants). Reports:
  - utide reconstruction skill per cell (how much of the current is tidal),
  - a spot-check that OUR predictor (validated convention) reproduces utide,
and writes the packed grid to dev/model/b1_grid.json.

Usage: python3 dev/model/b1_analyze.py [stride]   # stride>1 = quick subsample
"""
import sys, glob, json, time
sys.path.insert(0, "dev/model")
import numpy as np, xarray as xr, urllib.request, io, csv
import utide
from tidepredict import predict, CONSTITUENTS

RAW = ("/private/tmp/claude-501/-Users-bryan-salish-tides/"
       "04d3a9cd-e3ba-4fcf-8d41-13a614093def/scratchpad/b1_raw")
GY0, GY1, GX0, GX1 = 275, 325, 295, 375
NAMES = list(CONSTITUENTS.keys())
STRIDE = int(sys.argv[1]) if len(sys.argv) > 1 else 1

# --- load year of surface U/V over the box ---------------------------------
U = xr.open_mfdataset(sorted(glob.glob(f"{RAW}/uVelocity_*.nc")),
                      combine="by_coords")["uVelocity"].squeeze()
V = xr.open_mfdataset(sorted(glob.glob(f"{RAW}/vVelocity_*.nc")),
                      combine="by_coords")["vVelocity"].squeeze()
t64 = U["time"].values
Ua, Va = U.values, V.values                       # [T, Y, X]
print(f"loaded U/V {Ua.shape}, {len(t64)} hourly steps "
      f"{str(t64[0])[:13]}..{str(t64[-1])[:13]}")

# --- lat/lon for the box (curvilinear, from bathymetry) --------------------
geo = ("https://salishsea.eos.ubc.ca/erddap/griddap/ubcSSnBathymetryV21-08.csv?"
       f"longitude%5B{GY0}:{GY1}%5D%5B{GX0}:{GX1}%5D,"
       f"latitude%5B{GY0}:{GY1}%5D%5B{GX0}:{GX1}%5D")
rows = list(csv.reader(io.StringIO(urllib.request.urlopen(geo, timeout=120).read().decode())))[2:]
ny, nx = Ua.shape[1], Ua.shape[2]
LON = np.full((ny, nx), np.nan); LAT = np.full((ny, nx), np.nan)
for r in rows:
    if not r: continue
    iy, ix = int(r[0]) - GY0, int(r[1]) - GX0
    if 0 <= iy < ny and 0 <= ix < nx:
        LON[iy, ix] = float(r[2]); LAT[iy, ix] = float(r[3])

# --- water mask: finite and not identically zero ---------------------------
water = np.isfinite(Ua).all(axis=0) & (np.nanmax(np.abs(Ua), axis=0) > 1e-6)
cells = [(iy, ix) for iy in range(0, ny, STRIDE) for ix in range(0, nx, STRIDE)
         if water[iy, ix]]
print(f"{water.sum()} water cells; processing {len(cells)} (stride {STRIDE})")

def fit(series, lat):
    c = utide.solve(t64, series, lat=lat, constit=NAMES, method="ols",
                    conf_int="none", trend=False, verbose=False)
    return {n: (float(a), float(g)) for n, a, g in zip(c["name"], c["A"], c["g"])}, c

grid, skills = [], []
spot = []          # our-predictor cross-check on a few cells
t0 = time.time()
for k, (iy, ix) in enumerate(cells):
    lat = float(LAT[iy, ix])
    u, v = Ua[:, iy, ix], Va[:, iy, ix]
    ucon, uc = fit(u, lat)
    vcon, vc = fit(v, lat)
    ru = utide.reconstruct(t64, uc, verbose=False)["h"]
    rv = utide.reconstruct(t64, vc, verbose=False)["h"]
    sk_u = 1 - np.sum((u-ru)**2)/np.sum((u-u.mean())**2)
    sk_v = 1 - np.sum((v-rv)**2)/np.sum((v-v.mean())**2)
    skills.append((sk_u, sk_v))
    node = {n: {"uAmp": ucon[n][0], "uPhase": ucon[n][1],
                "vAmp": vcon[n][0], "vPhase": vcon[n][1]} for n in NAMES}
    grid.append({"lat": lat, "lon": float(LON[iy, ix]),
                 "gridY": iy+GY0, "gridX": ix+GX0, "c": node})
    if k < 3:    # our-predictor reproduces utide? (convention already proven)
        idx = np.linspace(0, len(t64)-1, 200).astype(int)
        from datetime import datetime
        ts = [datetime.utcfromtimestamp(t64[i].astype("datetime64[s]").astype(int)) for i in idx]
        myu = np.array([predict([{"name":n,"amp":ucon[n][0],"phase":ucon[n][1]} for n in NAMES], t) for t in ts])
        spot.append(float(np.sqrt(np.mean((myu - ru[idx])**2))))
    if (k+1) % 100 == 0:
        print(f"  {k+1}/{len(cells)}  {time.time()-t0:.0f}s", flush=True)

sk = np.array(skills)
print(f"\nutide reconstruction skill over {len(cells)} cells:")
print(f"  U: median {np.median(sk[:,0]):.3f}  10th pct {np.percentile(sk[:,0],10):.3f}")
print(f"  V: median {np.median(sk[:,1]):.3f}  10th pct {np.percentile(sk[:,1],10):.3f}")
print(f"our-predictor vs utide RMS (m/s) on spot cells: "
      f"{[round(s,5) for s in spot]}")

# Bellingham Bay cells (the atlas-gap target): gridX >= 360
bham = [(g, s) for g, s in zip(grid, skills) if g["gridX"] >= 360]
if bham:
    bs = np.array([s for _, s in bham])
    print(f"Bellingham Bay (gridX>=360): {len(bham)} cells, "
          f"U skill median {np.median(bs[:,0]):.3f}")

out = "dev/model/b1_grid.json"
json.dump({"box": [GY0, GY1, GX0, GX1], "year": 2023, "constituents": NAMES,
           "nodes": grid}, open(out, "w"))
import os
print(f"wrote {out}  ({os.path.getsize(out)/1e6:.2f} MB, {len(grid)} nodes)")
