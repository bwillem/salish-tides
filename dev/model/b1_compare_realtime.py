#!/usr/bin/env python3
"""B1 validation — our harmonic predictor vs recent SalishSeaCast surface output.

The constituents were solved from the 2023 surface hindcast. This asks the real
question for the offline "harmonic baseline": does predicting forward ~3 years
still track what the model actually produces? We pull the most RECENT ~29 days
of surface U/V (ends ~yesterday) at strong, high-skill cells spread across the
domain, reconstruct the same span from our constituents, and compare.

Because SalishSeaCast surface current carries wind + Fraser + baroclinic flow on
top of tide, agreement is expected to be high only where the tidal signal
dominates — exactly the strong channels a boater navigates.
"""
import sys, json, glob, io, csv
sys.path.insert(0, "dev/model")
import numpy as np
from datetime import datetime, timezone, timedelta
from tidepredict import astro, node_factors, equilibrium, CONSTITUENTS
from b1_download_full import fetch_bytes          # robust wall-clock retry fetch

BASE = "https://salishsea.eos.ubc.ca/erddap/griddap"
UDS, VDS = "ubcSSg3DuGridFields1hV21-11", "ubcSSg3DvGridFields1hV21-11"
K = list(CONSTITUENTS)

# --- pick strong, high-skill, well-separated cells from the analysis --------
cells = []
for p in sorted(glob.glob("dev/model/b1_grid_full.parts/tile_*.json")):
    for n in json.load(open(p))["nodes"]:
        if n["strength"] > 0.4 and np.isfinite(n["skillVec"]) and n["skillVec"] > 0.8:
            cells.append(n)
cells.sort(key=lambda n: -n["strength"])
picked, used = [], []
for n in cells:                       # greedy spatial spread
    if all(abs(n["lat"]-m["lat"]) + abs(n["lon"]-m["lon"]) > 0.15 for m in used):
        picked.append(n); used.append(n)
    if len(picked) == 6:
        break
print(f"{len(cells)} strong high-skill cells; testing {len(picked)} spread across domain\n")

# --- comparison window: most recent 29 days (spring-neap), hourly -----------
T1 = datetime(2026, 7, 13, 23, 30, tzinfo=timezone.utc)
T0 = T1 - timedelta(days=29)
ts_iso0 = T0.strftime("%Y-%m-%dT%H:%M:%SZ")
ts_iso1 = T1.strftime("%Y-%m-%dT%H:%M:%SZ")

def fetch_series(dsid, var, gy, gx):
    url = (f"{BASE}/{dsid}.csv?{var}"
           f"%5B({ts_iso0}):({ts_iso1})%5D%5B0%5D%5B{gy}%5D%5B{gx}%5D")
    data = fetch_bytes(url, retries=5, timeout=200)   # point time series can be slow
    if not data:
        raise IOError(f"fetch failed for {var} at {gy},{gx}")
    rows = list(csv.reader(io.StringIO(data.decode())))[2:]
    t, val = [], []
    for r in rows:
        if not r or r[-1] in ("", "NaN"):
            continue
        t.append(np.datetime64(r[0].replace("Z", "")))
        val.append(float(r[-1]))
    return np.array(t), np.array(val)

def predict_uv(node, times):
    """Reconstruct our harmonic U,V (m/s) at the given np.datetime64 times."""
    c = node["c"]
    uA = np.array([c[n]["uAmp"] for n in K]); uP = np.radians([c[n]["uPhase"] for n in K])
    vA = np.array([c[n]["vAmp"] for n in K]); vP = np.radians([c[n]["vPhase"] for n in K])
    ARG = np.zeros((len(times), len(K))); F = np.zeros((len(times), len(K)))
    for i, t64 in enumerate(times):
        t = datetime.fromtimestamp(t64.astype("datetime64[s]").astype(int), timezone.utc)
        a = astro(t)
        for ki, nm in enumerate(K):
            f, u = node_factors(nm, a["N"]); ARG[i, ki] = equilibrium(nm, a) + u; F[i, ki] = f
    ARGr = np.radians(ARG)
    u = (F * uA * np.cos(ARGr - uP)).sum(1) + node["uMean"]
    v = (F * vA * np.cos(ARGr - vP)).sum(1) + node["vMean"]
    return u, v

def vskill(ou, ov, pu, pv):
    res = np.sum((ou-pu)**2 + (ov-pv)**2)
    tot = np.sum((ou-ou.mean())**2 + (ov-ov.mean())**2)
    return np.nan if tot < 1e-9 else 1 - res/tot

print(f"window {ts_iso0[:10]} .. {ts_iso1[:10]}  (surface, out-of-sample vs 2023 fit)\n")
print(f"{'lat':>7} {'lon':>9} {'skillfit':>8} | {'corr':>5} {'RMS':>6} {'peakOBS':>7} {'peakPRED':>8} {'vskill':>6}")
rows = []
for n in picked:
    gy, gx = n["gridY"], n["gridX"]
    tu, ou = fetch_series(UDS, "uVelocity", gy, gx)
    tv, ov = fetch_series(VDS, "vVelocity", gy, gx)
    m = min(len(tu), len(tv))
    if m < 24:
        print(f"{n['lat']:7.3f} {n['lon']:9.3f}  (insufficient data)"); continue
    tu, ou, ov = tu[:m], ou[:m], ov[:m]
    pu, pv = predict_uv(n, tu)
    spd_o = np.hypot(ou, ov); spd_p = np.hypot(pu, pv)
    corr = np.corrcoef(np.r_[ou, ov], np.r_[pu, pv])[0, 1]
    rms = np.sqrt(np.mean((ou-pu)**2 + (ov-pv)**2))
    vs = vskill(ou, ov, pu, pv)
    rows.append((corr, rms, vs))
    print(f"{n['lat']:7.3f} {n['lon']:9.3f} {n['skillVec']:8.3f} | "
          f"{corr:5.2f} {rms:6.3f} {spd_o.max():7.2f} {spd_p.max():8.2f} {vs:6.3f}")

if rows:
    a = np.array(rows)
    print(f"\nmedian across {len(rows)} cells:  corr {np.median(a[:,0]):.2f}  "
          f"RMS {np.median(a[:,1]):.3f} m/s  vector-skill {np.median(a[:,2]):.3f}")
    print("(vector-skill here = how much of the LIVE current our offline "
          "harmonic baseline reproduces, 3 years out of sample)")
