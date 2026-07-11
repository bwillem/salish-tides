#!/usr/bin/env python3
"""B1 full-domain download (stride-2 / ~1km).

Generalizes b1_download.py from the single PoC box to the whole SalishSeaCast
grid, tiled and resumable. Downloads a year of surface U/V at stride 2 (the
app's ~1km target resolution) as monthly NetCDF chunks per tile. Skips files
already on disk, so it can be relaunched freely.

Grid: gridY 0-897, gridX 0-397. Tiles are 150x150 native cells; stride-2
sampling within each tile stays on the global even-index grid (all tile
origins are even), so tiles mosaic without gaps or overlaps.
"""
import urllib.request, os, time, sys

BASE = "https://salishsea.eos.ubc.ca/erddap/griddap"
YEAR = 2023
STRIDE = 2
TY, TX = 150, 150                      # native tile size
GY_MAX, GX_MAX = 897, 397
OUT = ("/private/tmp/claude-501/-Users-bryan-salish-tides/"
       "04d3a9cd-e3ba-4fcf-8d41-13a614093def/scratchpad/b1_full")
VARS = {"uVelocity": "ubcSSg3DuGridFields1hV21-11",
        "vVelocity": "ubcSSg3DvGridFields1hV21-11"}
os.makedirs(OUT, exist_ok=True)

def month_range(y, m):
    nm, ny = (1, y+1) if m == 12 else (m+1, y)
    return f"{y}-{m:02d}-01T00:30:00Z", f"{ny}-{nm:02d}-01T00:30:00Z"

def tiles():
    for gy0 in range(0, GY_MAX+1, TY):
        for gx0 in range(0, GX_MAX+1, TX):
            yield gy0, min(gy0+TY-1, GY_MAX), gx0, min(gx0+TX-1, GX_MAX)

def fetch(url, path):
    for attempt in range(1, 5):
        try:
            data = urllib.request.urlopen(url, timeout=600).read()
            with open(path, "wb") as f:
                f.write(data)
            return len(data)
        except Exception as e:
            print(f"    retry {attempt}/4: {e}", flush=True)
            time.sleep(10 * attempt)
    return None

def main():
    tile_list = list(tiles())
    print(f"full-domain download: {len(tile_list)} tiles, stride {STRIDE}, year {YEAR}")
    t_start = time.time()
    got_bytes = 0
    for ti, (gy0, gy1, gx0, gx1) in enumerate(tile_list):
        tdir = f"{OUT}/tile_{gy0:03d}_{gx0:03d}"
        os.makedirs(tdir, exist_ok=True)
        for var, ds in VARS.items():
            for m in range(1, 13):
                path = f"{tdir}/{var}_{YEAR}{m:02d}.nc"
                if os.path.exists(path) and os.path.getsize(path) > 500:
                    continue
                t0, t1 = month_range(YEAR, m)
                url = (f"{BASE}/{ds}.nc?{var}"
                       f"%5B({t0}):({t1})%5D%5B0%5D"
                       f"%5B{gy0}:{STRIDE}:{gy1}%5D%5B{gx0}:{STRIDE}:{gx1}%5D")
                n = fetch(url, path)
                if n is None:
                    print(f"  GAVE UP tile {ti} {var} {YEAR}-{m:02d}", flush=True)
                    sys.exit(1)
                got_bytes += n
        el = (time.time()-t_start)/60
        print(f"  tile {ti+1}/{len(tile_list)} gY[{gy0},{gy1}] gX[{gx0},{gx1}] done "
              f"| {got_bytes/1e6:.0f}MB new, {el:.0f}min elapsed", flush=True)
    print(f"DONE full-domain download: {got_bytes/1e6:.0f}MB new in {(time.time()-t_start)/60:.0f}min")

if __name__ == "__main__":
    main()
