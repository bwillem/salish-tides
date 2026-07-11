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

# ERDDAP drops connections (IncompleteRead / "Remote end closed") when hammered
# continuously, so retry generously with long backoff and stay polite between
# requests. The last resort is a smaller time chunk (handled in fetch_month).
RETRIES = 8
BACKOFF = [15, 30, 60, 90, 120, 150, 180, 180]
POLITE_SLEEP = 3          # seconds between requests, to not overload ERDDAP

def fetch(url, path):
    for attempt in range(RETRIES):
        try:
            # Short-ish timeout so a socket left dead by a sleep/wake cycle fails
            # fast and gets retried, rather than hanging on a frozen connection.
            data = urllib.request.urlopen(url, timeout=240).read()
            if len(data) < 500:
                raise IOError(f"suspiciously small response ({len(data)} bytes)")
            with open(path, "wb") as f:
                f.write(data)
            return len(data)
        except Exception as e:
            wait = BACKOFF[min(attempt, len(BACKOFF)-1)]
            print(f"    retry {attempt+1}/{RETRIES} (wait {wait}s): {e}", flush=True)
            time.sleep(wait)
    return None

def all_targets():
    """Every (tile, var, month) file we need, with its request params."""
    out = []
    for gy0, gy1, gx0, gx1 in tiles():
        tdir = f"{OUT}/tile_{gy0:03d}_{gx0:03d}"
        for var, ds in VARS.items():
            for m in range(1, 13):
                out.append((tdir, var, ds, m, gy0, gy1, gx0, gx1,
                            f"{tdir}/{var}_{YEAR}{m:02d}.nc"))
    return out

def have(path):
    return os.path.exists(path) and os.path.getsize(path) > 500

def main():
    targets = all_targets()
    total = len(targets)
    print(f"full-domain download: {total} files, stride {STRIDE}, year {YEAR}", flush=True)
    t_start = time.time()
    # Never-give-up multi-pass loop: a file that fails all its retries is simply
    # left for the next pass, so a bad ERDDAP patch never aborts the run. Exits 0
    # only when every file is present -- which (with the skip-if-have check) makes
    # the whole thing fully resumable after any interruption.
    pass_num = 0
    while True:
        miss = [t for t in targets if not have(t[-1])]
        done = total - len(miss)
        el = (time.time() - t_start) / 60
        print(f"pass {pass_num}: {done}/{total} present, {len(miss)} to fetch "
              f"({el:.0f}min elapsed)", flush=True)
        if not miss:
            break
        for tdir, var, ds, m, gy0, gy1, gx0, gx1, path in miss:
            if have(path):
                continue
            os.makedirs(tdir, exist_ok=True)
            t0, t1 = month_range(YEAR, m)
            url = (f"{BASE}/{ds}.nc?{var}"
                   f"%5B({t0}):({t1})%5D%5B0%5D"
                   f"%5B{gy0}:{STRIDE}:{gy1}%5D%5B{gx0}:{STRIDE}:{gx1}%5D")
            n = fetch(url, path)
            if n:
                time.sleep(POLITE_SLEEP)     # be gentle on ERDDAP between hits
        pass_num += 1
        if [t for t in targets if not have(t[-1])]:
            print("  stragglers remain; resting 60s before next pass", flush=True)
            time.sleep(60)
    print(f"DONE full-domain download in {(time.time()-t_start)/60:.0f}min", flush=True)

if __name__ == "__main__":
    main()
