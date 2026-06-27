#!/usr/bin/env python3
"""B1 PoC stage 1 — download one year of surface currents over the
Bellingham/Rosario box from the SalishSeaCast green hindcast, as compact
monthly NetCDF chunks. Whole-grid-block-per-time-range requests (not the slow
per-point 3-D extraction). Output goes to the scratchpad (big intermediates,
not the repo)."""
import urllib.request, os, time, sys

BASE = "https://salishsea.eos.ubc.ca/erddap/griddap"
GY0, GY1, GX0, GX1 = 275, 325, 295, 375     # Bellingham Bay + Rosario Strait
YEAR = 2023
OUT = ("/private/tmp/claude-501/-Users-bryan-salish-tides/"
       "04d3a9cd-e3ba-4fcf-8d41-13a614093def/scratchpad/b1_raw")
VARS = {"uVelocity": "ubcSSg3DuGridFields1hV21-11",
        "vVelocity": "ubcSSg3DvGridFields1hV21-11"}
os.makedirs(OUT, exist_ok=True)

def month_range(y, m):
    t0 = f"{y}-{m:02d}-01T00:30:00Z"
    nm, ny = (1, y+1) if m == 12 else (m+1, y)
    # last hour of month = first hour of next month minus 1h; ERDDAP clamps fine
    t1 = f"{ny}-{nm:02d}-01T00:30:00Z"
    return t0, t1

total = 0.0
for var, ds in VARS.items():
    for m in range(1, 13):
        path = f"{OUT}/{var}_{YEAR}{m:02d}.nc"
        if os.path.exists(path) and os.path.getsize(path) > 1000:
            print(f"  skip {os.path.basename(path)} ({os.path.getsize(path)/1e6:.1f}MB)")
            continue
        t0, t1 = month_range(YEAR, m)
        url = (f"{BASE}/{ds}.nc?{var}%5B({t0}):({t1})%5D%5B0%5D"
               f"%5B{GY0}:{GY1}%5D%5B{GX0}:{GX1}%5D")
        data = None
        for attempt in range(1, 5):                 # retry transient timeouts
            t = time.time()
            try:
                data = urllib.request.urlopen(url, timeout=600).read()
                break
            except Exception as e:
                print(f"  retry {attempt}/4 {var} {YEAR}-{m:02d}: {e}", flush=True)
                time.sleep(10 * attempt)
        if data is None:
            print(f"  GAVE UP {var} {YEAR}-{m:02d}", flush=True)
            sys.exit(1)
        with open(path, "wb") as f:
            f.write(data)
        dt = time.time() - t; total += dt
        print(f"  got {os.path.basename(path)}  {len(data)/1e6:.1f}MB  {dt:.0f}s", flush=True)

print(f"DONE downloading box {YEAR} (gY[{GY0},{GY1}] gX[{GX0},{GX1}]) in {total/60:.1f} min")
