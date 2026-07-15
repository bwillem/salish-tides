#!/usr/bin/env python3
"""B1 PoC stage 3 — sanity-check the NEMO-harmonic baseline against the Dewey
atlas where they overlap (Rosario Strait channel; the atlas has no data in the
bays, so those are naturally excluded). Both are tidal, so they should agree.

For a span of times in the atlas's bundled year (2026), look up the atlas chart,
gather its arrows inside the PoC box, predict the NEMO-harmonic current at each
arrow location/time, and compare speed + direction.
"""
import sys, json, glob, math
sys.path.insert(0, "dev/model")
import numpy as np
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from scipy.spatial import cKDTree
from tidepredict import predict, CONSTITUENTS

REPO = "/Users/bryan/salish-tides"
GRID = "dev/model/b1_grid.json"
NAMES = list(CONSTITUENTS.keys())
UTC, LOCAL = ZoneInfo("UTC"), ZoneInfo("America/Vancouver")

# --- NEMO-harmonic predictor over the PoC constituent grid -----------------
g = json.load(open(GRID))
nodes = g["nodes"]
tree = cKDTree([(n["lat"], n["lon"]) for n in nodes])
LATB = (min(n["lat"] for n in nodes), max(n["lat"] for n in nodes))
LONB = (min(n["lon"] for n in nodes), max(n["lon"] for n in nodes))

def nemo_uv(lat, lon, dt):
    d, i = tree.query((lat, lon))
    if d > 0.02:           # > ~2 km from any water node → no comparison
        return None
    c = nodes[i]["c"]
    u = predict([{"name": n, "amp": c[n]["uAmp"], "phase": c[n]["uPhase"]} for n in NAMES], dt)
    v = predict([{"name": n, "amp": c[n]["vAmp"], "phase": c[n]["vPhase"]} for n in NAMES], dt)
    spd = math.hypot(u, v)
    dirn = (math.degrees(math.atan2(u, v)) + 360) % 360   # compass, toward
    return spd, dirn

# --- atlas: time -> chart -> arrows ----------------------------------------
lut = json.load(open(f"{REPO}/SalishTides/Resources/atlas_lookup_2026.json"))
def atlas_chart(dt_local):
    row = lut["grid"].get(str(dt_local.month), {}).get(str(dt_local.day))
    if not row or dt_local.hour >= len(row):
        return None
    return row[dt_local.hour]

_cache = {}
def atlas_arrows(chart):
    if chart in _cache: return _cache[chart]
    pts = []
    for f in glob.glob(f"{REPO}/data/maps/map_{chart}_*.json"):
        for a in json.load(open(f)):
            if LATB[0] <= a["lat"] <= LATB[1] and LONB[0] <= a["lon"] <= LONB[1]:
                pts.append(a)
    _cache[chart] = pts
    return pts

# --- compare over a day, hourly --------------------------------------------
def wrap180(x): return (x + 180) % 360 - 180
day = datetime(2026, 6, 15, 0, 0, tzinfo=LOCAL)        # representative day
sp_a, sp_n, dterr, n_at = [], [], [], 0
for h in range(24):
    tl = day + timedelta(hours=h)
    tu = tl.astimezone(UTC)
    chart = atlas_chart(tl)
    if chart is None: continue
    for a in atlas_arrows(chart):
        if a["speed_ms"] <= 0: continue
        r = nemo_uv(a["lat"], a["lon"], tu)
        if r is None: continue
        n_at += 1
        sp_a.append(a["speed_ms"]); sp_n.append(r[0])
        # direction only meaningful when both are flowing
        if a["speed_ms"] > 0.15 and r[0] > 0.15:
            dterr.append(abs(wrap180(a["direction_deg"] - r[1])))

sp_a, sp_n = np.array(sp_a), np.array(sp_n)
print(f"compared {n_at} atlas arrows x hours in the box overlap (Rosario)")
print(f"speed: atlas mean {sp_a.mean():.3f}  nemo mean {sp_n.mean():.3f} m/s")
print(f"  bias {np.mean(sp_n-sp_a):+.3f}  RMS {np.sqrt(np.mean((sp_n-sp_a)**2)):.3f} m/s"
      f"  corr {np.corrcoef(sp_a,sp_n)[0,1]:.3f}")
if dterr:
    de = np.array(dterr)
    print(f"direction (both >0.15 m/s, n={len(de)}): median |Δ| {np.median(de):.1f}°"
          f"  flip>90° {100*np.mean(de>90):.0f}% (high ⇒ toward/from convention diff)")
