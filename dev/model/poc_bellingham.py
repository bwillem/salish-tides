#!/usr/bin/env python3
"""Proof-of-concept: harmonic-analyze SalishSeaCast currents at one Bellingham
Bay grid point and verify the tidal prediction reconstructs the signal.

Pulls 1 yr of hourly near-surface U/V from the green hindcast via ERDDAP,
runs utide, reports constituents + reconstruction skill. This is the smallest
end-to-end test of the offline model-currents pipeline (acquire → analyse →
predict)."""
import urllib.request, io, csv
import numpy as np
from datetime import datetime, timezone
import utide

GY, GX = 296, 362           # Bellingham Bay node (48.72N, -122.50W)
LAT = 48.7182
T0, T1 = "2023-01-01T00:30:00Z", "2023-12-31T23:30:00Z"
BASE = "https://salishsea.eos.ubc.ca/erddap/griddap"

def fetch(dataset, var):
    url = (f"{BASE}/{dataset}.csv?{var}"
           f"%5B({T0}):({T1})%5D%5B(0.5)%5D%5B({GY})%5D%5B({GX})%5D")
    print(f"  downloading {var} ...")
    raw = urllib.request.urlopen(url, timeout=120).read().decode()
    rows = list(csv.reader(io.StringIO(raw)))
    # rows[0]=names, rows[1]=units, rest=data: time,depth,gridY,gridX,<var>
    times, vals = [], []
    for r in rows[2:]:
        if not r or r[-1] == "" or r[-1] == "NaN":
            continue
        times.append(datetime.fromisoformat(r[0].replace("Z", "+00:00")))
        vals.append(float(r[-1]))
    return np.array(times), np.array(vals)

print("Bellingham Bay PoC — fetching 1 yr hourly surface currents")
tu, u = fetch("ubcSSg3DuGridFields1hV21-11", "uVelocity")
tv, v = fetch("ubcSSg3DvGridFields1hV21-11", "vVelocity")
assert len(tu) == len(tv) and (tu == tv).all(), "u/v time mismatch"
print(f"  {len(u)} hourly samples; |speed| max={np.hypot(u,v).max():.3f} m/s, "
      f"mean={np.hypot(u,v).mean():.3f} m/s")

# matplotlib datenum
import matplotlib.dates as mdates
t = mdates.date2num(tu)

coef = utide.solve(t, u, v, lat=LAT, method="ols", conf_int="MC", verbose=False)
print("\nTop constituents (by current ellipse semi-major axis):")
order = np.argsort(coef["Lsmaj"])[::-1]
for i in order[:8]:
    print(f"  {coef['name'][i]:4s}  Lmaj={coef['Lsmaj'][i]:.3f} m/s  "
          f"Lmin={coef['Lsmin'][i]:+.3f}  inc={coef['theta'][i]:6.1f}°  "
          f"phase={coef['g'][i]:6.1f}°")

# Reconstruct over the same period and score skill
rec = utide.reconstruct(t, coef, verbose=False)
ru, rv = rec["u"], rec["v"]
def skill(obs, pred):
    return 1 - np.sum((obs-pred)**2)/np.sum((obs-obs.mean())**2)
print(f"\nReconstruction skill (1=perfect): u={skill(u,ru):.3f}  v={skill(v,rv):.3f}")
print(f"RMS residual: u={np.sqrt(np.mean((u-ru)**2)):.3f}  "
      f"v={np.sqrt(np.mean((v-rv)**2)):.3f} m/s  "
      f"(tidal signal RMS u={u.std():.3f} v={v.std():.3f})")
