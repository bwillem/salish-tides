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

# --- load year of surface U/V over the box (per-file, no dask) -------------
def load(var):
    arrs, times = [], []
    for f in sorted(glob.glob(f"{RAW}/{var}_*.nc")):
        ds = xr.open_dataset(f)
        da = ds[var].squeeze()                    # [time, gridY, gridX]
        arrs.append(da.values); times.append(da["time"].values)
        ds.close()
    return np.concatenate(arrs, 0), np.concatenate(times)
Ua, t64 = load("uVelocity")
Va, _ = load("vVelocity")
_, uidx = np.unique(t64, return_index=True)       # drop month-boundary dupes
Ua, Va, t64 = Ua[uidx], Va[uidx], t64[uidx]
print(f"loaded U/V {Ua.shape}, {len(t64)} hourly steps "
      f"{str(t64[0])[:13]}..{str(t64[-1])[:13]}")

def skill(o, r):
    den = np.sum((o - o.mean())**2)
    return float("nan") if den < 1e-9 else 1 - np.sum((o - r)**2) / den

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

grid, skills, strengths = [], [], []
spot = []          # our-predictor cross-check on a few cells
t0 = time.time()
for k, (iy, ix) in enumerate(cells):
    lat = float(LAT[iy, ix])
    u, v = Ua[:, iy, ix], Va[:, iy, ix]
    ucon, uc = fit(u, lat)
    vcon, vc = fit(v, lat)
    ru = utide.reconstruct(t64, uc, verbose=False)["h"]
    rv = utide.reconstruct(t64, vc, verbose=False)["h"]
    # vector skill: residual current energy vs total current energy (the metric
    # that matters — a strong tidal along-channel flow isn't undone by a weak,
    # noisy cross-channel component).
    res = np.sum((u-ru)**2 + (v-rv)**2)
    tot = np.sum((u-u.mean())**2 + (v-v.mean())**2)
    sk_vec = float("nan") if tot < 1e-9 else 1 - res/tot
    skills.append((skill(u, ru), skill(v, rv), sk_vec))
    strengths.append(float(np.hypot(u, v).std()))
    node = {n: {"uAmp": ucon[n][0], "uPhase": ucon[n][1],
                "vAmp": vcon[n][0], "vPhase": vcon[n][1]} for n in NAMES}
    grid.append({"lat": lat, "lon": float(LON[iy, ix]),
                 "gridY": iy+GY0, "gridX": ix+GX0,
                 "uMean": float(u.mean()), "vMean": float(v.mean()), "c": node})
    if k < 3:    # our-predictor reproduces utide? (convention already proven)
        idx = np.linspace(0, len(t64)-1, 200).astype(int)
        from datetime import datetime, timezone
        ts = [datetime.fromtimestamp(t64[i].astype("datetime64[s]").astype(int), timezone.utc) for i in idx]
        myu = np.array([predict([{"name":n,"amp":ucon[n][0],"phase":ucon[n][1]} for n in NAMES], t) for t in ts])
        # tidal-only comparison (utide's reconstruct carries the steady mean; ours doesn't)
        spot.append(float(np.sqrt(np.mean(((myu-myu.mean()) - (ru[idx]-ru[idx].mean()))**2))))
    if (k+1) % 100 == 0:
        print(f"  {k+1}/{len(cells)}  {time.time()-t0:.0f}s", flush=True)

sk = np.array(skills); st = np.array(strengths)
sig = st > 0.10        # cells with a meaningful tidal current (std > 0.1 m/s)
print(f"\nreconstruction skill (1=fully tidal) over {len(cells)} cells:")
print(f"  VECTOR current  — all water: median {np.nanmedian(sk[:,2]):.3f}")
print(f"  VECTOR current  — significant ({sig.sum()} cells): median "
      f"{np.nanmedian(sk[sig,2]):.3f}  10th pct {np.nanpercentile(sk[sig,2],10):.3f}")
print(f"  (components, significant: U {np.nanmedian(sk[sig,0]):.3f}  V {np.nanmedian(sk[sig,1]):.3f})")
print(f"our-predictor vs utide tidal RMS (m/s) on spot cells: "
      f"{[round(s,5) for s in spot]}")

out = "dev/model/b1_grid.json"
json.dump({"box": [GY0, GY1, GX0, GX1], "year": 2023, "constituents": NAMES,
           "nodes": grid}, open(out, "w"))
import os
print(f"wrote {out}  ({os.path.getsize(out)/1e6:.2f} MB, {len(grid)} nodes)")
