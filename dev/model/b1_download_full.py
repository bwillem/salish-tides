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
import urllib.request, os, time, sys, threading
from datetime import datetime, timedelta, timezone
import numpy as np, xarray as xr

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

# urllib's socket timeout does NOT reliably fire on a half-dead TCP connection
# left behind by a sleep/wake cycle, and a SIGALRM/itimer backstop is no good
# either: macOS suspends interval timers while the machine sleeps, so a sleep
# landing inside a socket read leaves the read wedged with the alarm frozen
# (observed: workers stuck 0% CPU for hours).
#
# The one clock that survives sleep is the wall clock (time.time() jumps forward
# by the sleep duration on wake). So run each fetch in a daemon thread and have
# the main thread abandon it once wall-clock elapsed exceeds HARD_TIMEOUT. A
# thread stuck on a dead socket is simply orphaned (it holds one doomed socket
# and errors out later) while we retry on a fresh connection. This self-heals a
# sleep-wedge within ~HARD_TIMEOUT of wake, no external watchdog required.
HARD_TIMEOUT = 300        # wall-clock seconds; > the 240s socket timeout
SLICE_DAYS = 10           # sub-month slice size for the heavy-tile fallback

def _url(var, ds, t0, t1, gy0, gy1, gx0, gx1):
    return (f"{BASE}/{ds}.nc?{var}"
            f"%5B({t0}):({t1})%5D%5B0%5D"
            f"%5B{gy0}:{STRIDE}:{gy1}%5D%5B{gx0}:{STRIDE}:{gx1}%5D")

def fetch_bytes(url, retries=RETRIES, timeout=240):
    """Download a URL to bytes, or None. Wall-clock thread timeout survives
    sleep/wake (see note above): a read wedged on a dead socket is abandoned
    once real time — not a suspendable itimer — passes HARD_TIMEOUT."""
    for attempt in range(retries):
        box = {}
        def _do():
            try:
                box["data"] = urllib.request.urlopen(url, timeout=timeout).read()
            except Exception as e:            # noqa: BLE001 (retry on anything)
                box["err"] = e
        th = threading.Thread(target=_do, daemon=True)
        start = time.time()                   # wall clock — advances across sleep
        th.start()
        while th.is_alive() and (time.time() - start) < HARD_TIMEOUT:
            th.join(5)
        try:
            if th.is_alive():
                raise TimeoutError(f"wall-clock timeout after {HARD_TIMEOUT}s "
                                   f"(likely dead socket after sleep) — abandoning")
            if "err" in box:
                raise box["err"]
            data = box["data"]
            if len(data) < 500:
                raise IOError(f"suspiciously small response ({len(data)} bytes)")
            return data
        except Exception as e:
            wait = BACKOFF[min(attempt, len(BACKOFF)-1)]
            print(f"    retry {attempt+1}/{retries} (wait {wait}s): {e}", flush=True)
            time.sleep(wait)
    return None

def month_slices(y, m, days=SLICE_DAYS):
    """Yield (t0,t1) ISO sub-ranges tiling month m. Ranges are inclusive on both
    ends in ERDDAP, so consecutive slices share a boundary hour — harmless, the
    concat step drops the duplicate timestamp."""
    start = datetime(y, m, 1, 0, 30, tzinfo=timezone.utc)
    nm, ny = (1, y+1) if m == 12 else (m+1, y)
    end = datetime(ny, nm, 1, 0, 30, tzinfo=timezone.utc)
    a = start
    while a < end:
        b = min(a + timedelta(days=days), end)
        yield (a.strftime("%Y-%m-%dT%H:%M:%SZ"), b.strftime("%Y-%m-%dT%H:%M:%SZ"))
        a = b

def fetch_file(var, ds, m, gy0, gy1, gx0, gx1, path):
    """Fetch one month to `path`. Tries the whole month first (cheap for most
    tiles); the tall northern/eastern edge tiles are too heavy for ERDDAP to
    serve in one request and time out, so fall back to SLICE_DAYS sub-requests
    concatenated into the same monthly NetCDF the analyzer expects."""
    t0, t1 = month_range(YEAR, m)
    data = fetch_bytes(_url(var, ds, t0, t1, gy0, gy1, gx0, gx1),
                       retries=1, timeout=180)     # one quick try, then slice
    if data:
        with open(path, "wb") as f:
            f.write(data)
        return len(data)
    print(f"    whole-month failed; slicing {var} {YEAR}-{m:02d} "
          f"tile {gy0},{gx0}", flush=True)
    parts = []
    try:
        for i, (s0, s1) in enumerate(month_slices(YEAR, m)):
            d = fetch_bytes(_url(var, ds, s0, s1, gy0, gy1, gx0, gx1),
                            retries=4, timeout=200)
            if not d:
                print(f"    slice {s0}..{s1} failed — leave file for next pass",
                      flush=True)
                return None
            pp = f"{path}.part{i}"
            with open(pp, "wb") as f:
                f.write(d)
            parts.append(pp)
        dsx = [xr.open_dataset(p) for p in parts]
        combined = xr.concat(dsx, dim="time")
        _, idx = np.unique(combined["time"].values, return_index=True)
        combined = combined.isel(time=np.sort(idx))
        combined.to_netcdf(path + ".tmp")
        for d_ in dsx:
            d_.close()
        os.replace(path + ".tmp", path)
        return os.path.getsize(path)
    finally:
        for p in parts:
            try:
                os.remove(p)
            except OSError:
                pass

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
            n = fetch_file(var, ds, m, gy0, gy1, gx0, gx1, path)
            if n:
                time.sleep(POLITE_SLEEP)     # be gentle on ERDDAP between hits
        pass_num += 1
        if [t for t in targets if not have(t[-1])]:
            print("  stragglers remain; resting 60s before next pass", flush=True)
            time.sleep(60)
    print(f"DONE full-domain download in {(time.time()-t_start)/60:.0f}min", flush=True)

if __name__ == "__main__":
    main()
