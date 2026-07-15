#!/usr/bin/env python3
"""B1 PoC stage 3b — phase-independent atlas comparison.

Instead of instantaneous speeds (phase-sensitive, noisy across two different
models with the atlas quantized to 43 charts), compare the PEAK tidal current
per location: the max current magnitude over a spring-neap cycle. This asks the
clean question — do NEMO-harmonic and the Dewey atlas agree on where the
current is strong vs weak, and on its magnitude?

  NEMO peak  = max |current| over 29 days, reconstructed from our constituents.
  Atlas peak = max speed over the 43 phase charts at the same location.
"""
import sys, json, glob
sys.path.insert(0, "dev/model")
import numpy as np
from datetime import datetime, timezone, timedelta
from scipy.spatial import cKDTree
from tidepredict import astro, node_factors, equilibrium, CONSTITUENTS

REPO = "/Users/bryan/salish-tides"
K = list(CONSTITUENTS)
g = json.load(open("dev/model/b1_grid.json"))
nodes = g["nodes"]
LATB = (min(n["lat"] for n in nodes), max(n["lat"] for n in nodes))
LONB = (min(n["lon"] for n in nodes), max(n["lon"] for n in nodes))

# --- precompute the per-constituent phase arg & nodal factor over 29 days ---
t0 = datetime(2026, 6, 1, tzinfo=timezone.utc)
times = [t0 + timedelta(hours=i) for i in range(29 * 24)]      # spring-neap span
ARG = np.zeros((len(times), len(K))); F = np.zeros((len(times), len(K)))
for ti, t in enumerate(times):
    a = astro(t)
    for ki, n in enumerate(K):
        f, u = node_factors(n, a["N"]); ARG[ti, ki] = equilibrium(n, a) + u; F[ti, ki] = f
ARGr = np.radians(ARG)

def nemo_peak(node):
    c = node["c"]
    uA = np.array([c[n]["uAmp"] for n in K]); uP = np.radians([c[n]["uPhase"] for n in K])
    vA = np.array([c[n]["vAmp"] for n in K]); vP = np.radians([c[n]["vPhase"] for n in K])
    u = (F * uA * np.cos(ARGr - uP)).sum(1)
    v = (F * vA * np.cos(ARGr - vP)).sum(1)
    return float(np.hypot(u, v).max())

tree = cKDTree([(n["lat"], n["lon"]) for n in nodes])
node_peak = [nemo_peak(n) for n in nodes]

# --- atlas: peak speed per location across all 43 charts --------------------
atlas = {}        # (round lat,lon) -> max speed
for f in glob.glob(f"{REPO}/data/maps/map_*_*.json"):
    for a in json.load(open(f)):
        if LATB[0] <= a["lat"] <= LATB[1] and LONB[0] <= a["lon"] <= LONB[1]:
            key = (round(a["lat"], 4), round(a["lon"], 4))
            atlas[key] = max(atlas.get(key, 0.0), a["speed_ms"])
print(f"atlas: {len(atlas)} unique locations in the box overlap")

# --- match each atlas location to nearest NEMO node, compare peaks ----------
ap, npk = [], []
for (lat, lon), apeak in atlas.items():
    d, i = tree.query((lat, lon))
    if d > 0.006:            # > ~600 m → no co-located NEMO node
        continue
    ap.append(apeak); npk.append(node_peak[i])
ap, npk = np.array(ap), np.array(npk)
print(f"matched {len(ap)} locations (atlas arrow within ~600 m of a NEMO node)\n")

print(f"PEAK tidal current per location:")
print(f"  atlas mean {ap.mean():.3f}  NEMO mean {npk.mean():.3f} m/s")
print(f"  ratio NEMO/atlas: median {np.median(npk/np.maximum(ap,0.05)):.2f}")
print(f"  spatial correlation: {np.corrcoef(ap, npk)[0,1]:.3f}")
print(f"  RMS {np.sqrt(np.mean((npk-ap)**2)):.3f} m/s   bias {np.mean(npk-ap):+.3f} m/s")
# strong-current locations only (where it matters for navigation)
strong = ap > 0.5
print(f"  strong spots (atlas peak>0.5, n={strong.sum()}): "
      f"corr {np.corrcoef(ap[strong], npk[strong])[0,1]:.3f}  "
      f"ratio median {np.median(npk[strong]/ap[strong]):.2f}")
