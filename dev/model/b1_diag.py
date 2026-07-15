#!/usr/bin/env python3
"""Diagnose B1 skill: dedupe the time axis, then on the strongest-current cells
compare utide fit skill with our 8 astronomical constituents vs utide's 'auto'
selection (which adds overtides M4/M6/MS4 etc.). Tells us how many constituents
the harmonic baseline really needs."""
import sys, glob
sys.path.insert(0, "dev/model")
import numpy as np, xarray as xr
import utide
from tidepredict import CONSTITUENTS
RAW = ("/private/tmp/claude-501/-Users-bryan-salish-tides/"
       "04d3a9cd-e3ba-4fcf-8d41-13a614093def/scratchpad/b1_raw")
NAMES = list(CONSTITUENTS.keys())

def load(var):
    arrs, times = [], []
    for f in sorted(glob.glob(f"{RAW}/{var}_*.nc")):
        ds = xr.open_dataset(f); da = ds[var].squeeze()
        arrs.append(da.values); times.append(da["time"].values); ds.close()
    A = np.concatenate(arrs, 0); T = np.concatenate(times)
    _, uidx = np.unique(T, return_index=True)        # drop month-boundary dupes
    return A[uidx], T[uidx]

Ua, t64 = load("uVelocity"); Va, _ = load("vVelocity")
print(f"after dedupe: {len(t64)} steps  {str(t64[0])[:13]}..{str(t64[-1])[:13]}")
water = np.isfinite(Ua).all(0) & (np.nanmax(np.abs(Ua), 0) > 1e-6)

spd_std = np.where(water, np.hypot(Ua, Va).std(0), 0)    # find energetic cells
order = np.dstack(np.unravel_index(np.argsort(spd_std, None)[::-1], spd_std.shape))[0]

def skill(o, r):
    den = np.sum((o-o.mean())**2)
    return np.nan if den < 1e-9 else 1 - np.sum((o-r)**2)/den

print("\n  cell      |u|std |v|std  umean | sk8_u sk8_v | skAuto_u nconst | top auto consts")
for iy, ix in order[:6]:
    u, v = Ua[:, iy, ix], Va[:, iy, ix]
    c8u = utide.solve(t64, u, lat=48.6, constit=NAMES, method="ols", conf_int="none", trend=False, verbose=False)
    c8v = utide.solve(t64, v, lat=48.6, constit=NAMES, method="ols", conf_int="none", trend=False, verbose=False)
    r8u = utide.reconstruct(t64, c8u, verbose=False)["h"]
    r8v = utide.reconstruct(t64, c8v, verbose=False)["h"]
    cau = utide.solve(t64, u, lat=48.6, method="ols", conf_int="none", trend=False, verbose=False)
    rau = utide.reconstruct(t64, cau, verbose=False)["h"]
    o = np.argsort(cau["A"])[::-1]
    top = [f"{cau['name'][i]}:{cau['A'][i]:.2f}" for i in o[:6]]
    print(f"  ({iy:2d},{ix:2d}) {u.std():.3f} {v.std():.3f} {u.mean():+.2f} | "
          f"{skill(u,r8u):.3f} {skill(v,r8v):.3f} | {skill(u,rau):.3f}  {len(cau['name'])}    | {' '.join(top)}")
