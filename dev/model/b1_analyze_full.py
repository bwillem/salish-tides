#!/usr/bin/env python3
"""B1 full-domain stage 2 — harmonic-analyze every downloaded tile and pack a
single constituent grid for the whole SalishSeaCast domain.

Generalizes b1_analyze.py from the single PoC box to all 18 stride-2 tiles.
Each tile's NetCDF carries its real global gridY/gridX coords (0,2,4,...), so
tiles mosaic by coordinate with no overlap. For every water cell we utide-solve
U and V into per-constituent (amp, Greenwich phase) — exactly the form the Swift
`TidalCurrentField.NodeConstituent` wants.

Resumable: each tile's result is written to a part file under b1_grid_full.parts/
and skipped on re-run, so an interrupted analysis (sleep/reboot) picks up where
it left off. A final pass merges the parts into dev/model/b1_grid_full.json and
prints aggregate reconstruction skill.

Grid stride is auto-detected from the downloaded data's gridX spacing (1 =
native ~500m, 2 = ~1km), so the analyzer always matches whatever the downloader
fetched — no constant to keep in sync.

Usage: python3 dev/model/b1_analyze_full.py [--raw DIR] [--stride N]
                                            [--cell-stride N] [--year Y]
"""
import sys, os, glob, json, time, io, csv, math, cmath, urllib.request, argparse
sys.path.insert(0, "dev/model")
import numpy as np, xarray as xr
import utide
from tidepredict import predict, CONSTITUENTS

# Defaults target the native (~500m, stride-1) rebuild. main() overrides via
# argparse and, crucially, auto-detects STRIDE_TILE from the data so a stride
# mismatch can't silently drop cells (a stride-2 georef query against stride-1
# data would leave every odd-index cell without a lat/lon and skip it).
RAW = os.path.expanduser("~/salish-tides-nemo/b1_full_native")
PARTS = "dev/model/b1_grid_full.parts"
OUT = "dev/model/b1_grid_full.json"
YEAR = 2023
STRIDE_TILE = 1                       # native ~500m; auto-detected in main()
NAMES = list(CONSTITUENTS.keys())
CELL_STRIDE = 1                       # analyze every Nth water cell (1 = all)
GY_MAX, GX_MAX = 897, 397
os.makedirs(PARTS, exist_ok=True)

# --- lat/lon for the whole even-index grid, one bathymetry query -------------
def load_geo():
    # Stride-specific: the even-only (stride-2) grid and the full native
    # (stride-1) grid have different georef sets, so cache them separately.
    cache = f"{PARTS}/_geo_s{STRIDE_TILE}.json"
    if os.path.exists(cache):
        d = json.load(open(cache))
        return {tuple(map(int, k.split(","))): v for k, v in d.items()}
    url = ("https://salishsea.eos.ubc.ca/erddap/griddap/ubcSSnBathymetryV21-08.csv?"
           f"longitude%5B0:{STRIDE_TILE}:{GY_MAX}%5D%5B0:{STRIDE_TILE}:{GX_MAX}%5D,"
           f"latitude%5B0:{STRIDE_TILE}:{GY_MAX}%5D%5B0:{STRIDE_TILE}:{GX_MAX}%5D")
    rows = list(csv.reader(io.StringIO(
        urllib.request.urlopen(url, timeout=180).read().decode())))[2:]
    geo = {}
    for r in rows:
        if not r or len(r) < 4:
            continue
        try:
            gy, gx = int(r[0]), int(r[1]); lon, lat = float(r[2]), float(r[3])
        except ValueError:
            continue
        geo[(gy, gx)] = [lon, lat]
    json.dump({f"{k[0]},{k[1]}": v for k, v in geo.items()}, open(cache, "w"))
    return geo

# --- one tile's year of surface U/V, per-file, dedup month-boundary dupes ----
def load_tile_var(tdir, var):
    arrs, times = [], []
    for f in sorted(glob.glob(f"{tdir}/{var}_*.nc")):
        ds = xr.open_dataset(f)
        da = ds[var].squeeze()                       # [time, gridY, gridX]
        arrs.append(da.values)
        times.append(da["time"].values)
        gy = ds["gridY"].values.astype(int)
        gx = ds["gridX"].values.astype(int)
        ds.close()
    return np.concatenate(arrs, 0), np.concatenate(times), gy, gx

def skill(o, r):
    den = np.sum((o - o.mean())**2)
    return float("nan") if den < 1e-9 else 1 - np.sum((o - r)**2) / den

def fit(t64, series, lat):
    c = utide.solve(t64, series, lat=lat, constit=NAMES, method="ols",
                    conf_int="none", trend=False, verbose=False)
    con = {n: (float(a), float(g)) for n, a, g in zip(c["name"], c["A"], c["g"])}
    return con, c

def process_tile(tdir, geo, spot):
    Ua, t64, gy, gx = load_tile_var(tdir, "uVelocity")
    Va, _, _, _ = load_tile_var(tdir, "vVelocity")
    _, uidx = np.unique(t64, return_index=True)
    Ua, Va, t64 = Ua[uidx], Va[uidx], t64[uidx]
    ny, nx = Ua.shape[1], Ua.shape[2]
    water = np.isfinite(Ua).all(axis=0) & (np.nanmax(np.abs(Ua), axis=0) > 1e-6)
    cells = [(iy, ix) for iy in range(0, ny, CELL_STRIDE)
             for ix in range(0, nx, CELL_STRIDE) if water[iy, ix]]
    nodes = []
    t0 = time.time()
    for k, (iy, ix) in enumerate(cells):
        GY, GX = int(gy[iy]), int(gx[ix])
        ll = geo.get((GY, GX))
        if ll is None:                    # no bathy georef -> skip (rare edge)
            continue
        lon, lat = ll
        u, v = Ua[:, iy, ix], Va[:, iy, ix]
        ucon, uc = fit(t64, u, lat)
        vcon, vc = fit(t64, v, lat)
        ru = utide.reconstruct(t64, uc, verbose=False)["h"]
        rv = utide.reconstruct(t64, vc, verbose=False)["h"]
        res = np.sum((u-ru)**2 + (v-rv)**2)
        tot = np.sum((u-u.mean())**2 + (v-v.mean())**2)
        sk_vec = float("nan") if tot < 1e-9 else 1 - res/tot
        node = {n: {"uAmp": ucon[n][0], "uPhase": ucon[n][1],
                    "vAmp": vcon[n][0], "vPhase": vcon[n][1]} for n in NAMES}
        nodes.append({"lat": lat, "lon": lon, "gridY": GY, "gridX": GX,
                      "uMean": float(u.mean()), "vMean": float(v.mean()),
                      "strength": float(np.hypot(u, v).std()),
                      "skillVec": sk_vec, "skillU": skill(u, ru),
                      "skillV": skill(v, rv), "c": node})
        if len(spot) < 3:                 # our-predictor reproduces utide?
            from datetime import datetime, timezone
            idx = np.linspace(0, len(t64)-1, 200).astype(int)
            ts = [datetime.fromtimestamp(t64[i].astype("datetime64[s]").astype(int),
                                         timezone.utc) for i in idx]
            myu = np.array([predict([{"name": n, "amp": ucon[n][0],
                                      "phase": ucon[n][1]} for n in NAMES], t) for t in ts])
            spot.append(float(np.sqrt(np.mean(
                ((myu-myu.mean()) - (ru[idx]-ru[idx].mean()))**2))))
        if (k+1) % 500 == 0:
            print(f"    {k+1}/{len(cells)} cells  {time.time()-t0:.0f}s", flush=True)
    return nodes

def _infer_tile_stride(tiles):
    """Grid spacing of the downloaded data (1 = native ~500m, 2 = ~1km), read
    from the first tile's gridX, so the analyzer adapts to whatever was fetched
    instead of trusting a hand-set constant."""
    for tdir in tiles:
        fs = sorted(glob.glob(f"{tdir}/uVelocity_*.nc"))
        if not fs:
            continue
        ds = xr.open_dataset(fs[0]); gx = ds["gridX"].values.astype(int); ds.close()
        if len(gx) >= 2:
            return int(gx[1] - gx[0])
    return None

def main():
    global RAW, STRIDE_TILE, CELL_STRIDE, YEAR
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=RAW, help="downloaded-tiles dir")
    ap.add_argument("--stride", type=int, default=None,
                    help="grid stride of the data; auto-detected from gridX if omitted")
    ap.add_argument("--cell-stride", type=int, default=CELL_STRIDE,
                    help="analyze every Nth water cell (1 = all)")
    ap.add_argument("--year", type=int, default=YEAR)
    a = ap.parse_args()
    RAW, CELL_STRIDE, YEAR = os.path.expanduser(a.raw), a.cell_stride, a.year

    tiles = sorted(glob.glob(f"{RAW}/tile_*"))
    det = _infer_tile_stride(tiles)
    if a.stride is not None:
        STRIDE_TILE = a.stride
        if det is not None and det != STRIDE_TILE:
            print(f"  WARNING: --stride {STRIDE_TILE} but data gridX spacing is "
                  f"{det} — georef will mismatch and drop cells", flush=True)
    elif det is not None:
        STRIDE_TILE = det
    label = {1: "native ~500m", 2: "~1km"}.get(STRIDE_TILE, "custom")
    print(f"analyze: {len(tiles)} tile dirs in {RAW}", flush=True)
    print(f"grid stride {STRIDE_TILE} ({label}), cell-stride {CELL_STRIDE}, "
          f"year {YEAR}", flush=True)

    geo = load_geo()
    spot = []
    present, done, skipped = 0, 0, 0
    for tdir in tiles:
        name = os.path.basename(tdir)
        nu = len(glob.glob(f"{tdir}/uVelocity_*.nc"))
        nv = len(glob.glob(f"{tdir}/vVelocity_*.nc"))
        part = f"{PARTS}/{name}.json"
        if os.path.exists(part):
            done += 1
            continue
        if nu < 12 or nv < 12:            # tile not fully downloaded yet
            skipped += 1
            print(f"  {name}: incomplete (u={nu} v={nv}) — skip", flush=True)
            continue
        present += 1
        print(f"  {name}: analyzing…", flush=True)
        nodes = process_tile(tdir, geo, spot)
        json.dump({"tile": name, "nodes": nodes}, open(part, "w"))
        sk = np.array([n["skillVec"] for n in nodes], float)
        print(f"  {name}: {len(nodes)} water cells, median vec skill "
              f"{np.nanmedian(sk):.3f}", flush=True)

    # --- merge all completed parts ------------------------------------------
    parts = sorted(glob.glob(f"{PARTS}/tile_*.json"))
    grid, allsk, allst = [], [], []
    for p in parts:
        for n in json.load(open(p))["nodes"]:
            allsk.append((n["skillU"], n["skillV"], n["skillVec"]))
            allst.append(n["strength"])
            grid.append({"lat": n["lat"], "lon": n["lon"],
                         "gridY": n["gridY"], "gridX": n["gridX"],
                         "uMean": n["uMean"], "vMean": n["vMean"], "c": n["c"]})
    ntiles = 18
    print(f"\ntiles: {done+present} analyzed / {ntiles} total "
          f"({skipped} still downloading)")
    if not grid:
        print("no completed tiles yet — nothing to merge.")
        return
    sk = np.array(allsk); st = np.array(allst); sig = st > 0.10
    print(f"merged {len(grid)} water cells from {len(parts)} tiles")
    print(f"reconstruction skill (1=fully tidal):")
    print(f"  VECTOR — all water: median {np.nanmedian(sk[:,2]):.3f}")
    print(f"  VECTOR — significant ({sig.sum()} cells, std>0.1 m/s): median "
          f"{np.nanmedian(sk[sig,2]):.3f}  10th pct {np.nanpercentile(sk[sig,2],10):.3f}")
    print(f"  components (significant): U {np.nanmedian(sk[sig,0]):.3f}  "
          f"V {np.nanmedian(sk[sig,1]):.3f}")
    if spot:
        print(f"our-predictor vs utide tidal RMS (m/s): {[round(s,5) for s in spot]}")

    rotate_to_geographic(grid, geo)

    json.dump({"domain": [0, GY_MAX, 0, GX_MAX], "stride": STRIDE_TILE,
               "year": YEAR, "constituents": NAMES, "frame": "geographic",
               "nodes": grid}, open(OUT, "w"))
    print(f"wrote {OUT}  ({os.path.getsize(OUT)/1e6:.2f} MB, {len(grid)} nodes, "
          f"{len(parts)}/{ntiles} tiles)")


# --- grid frame → geographic east/north ---------------------------------------
# The GridFields datasets are NEMO grid-ALIGNED (ERDDAP standard_name
# sea_water_x_velocity), and the SalishSeaCast grid is rotated ~29° CCW from
# east — packing the raw components as east/north skewed every direction by
# that angle (measured −30.2° median vs the Dewey atlas before this step).
# Rotation is linear and time-invariant, so it commutes with the harmonic fit:
# rotating the fitted phasors here equals fitting rotated series. The grid-x
# direction is derived per node from the bathymetry georeference; grid-y is
# +90° from grid-x. (Known residual: u/v live on staggered points ~¼ cell from
# the T-point — unrecoverable post-fit, and well under the packer's 1.2 km
# nearest-assign tolerance.)
def rotate_to_geographic(grid, geo):
    def axis_angle(a, b, quarter_turns):
        pa, pb = geo.get(a), geo.get(b)
        if not pa or not pb:
            return None
        lat_mid = (pa[1] + pb[1]) / 2
        dE = (pb[0] - pa[0]) * math.cos(math.radians(lat_mid))
        dN = pb[1] - pa[1]
        return math.atan2(dN, dE) - quarter_turns * math.pi / 2

    def grid_x_angle(GY, GX):
        s = STRIDE_TILE
        for a, b, q in (((GY, GX-s), (GY, GX+s), 0),   # central diff on grid-x
                        ((GY, GX),   (GY, GX+s), 0),   # one-sided
                        ((GY, GX-s), (GY, GX),   0),
                        ((GY-s, GX), (GY+s, GX), 1),   # fall back to grid-y
                        ((GY, GX),   (GY+s, GX), 1),
                        ((GY-s, GX), (GY, GX),   1)):
            th = axis_angle(a, b, q)
            if th is not None:
                return th
        return None

    thetas = [grid_x_angle(n["gridY"], n["gridX"]) for n in grid]
    known = [t for t in thetas if t is not None]
    med = float(np.median(known))
    for n, th in zip(grid, thetas):
        if th is None:
            th = med
        ct, st = math.cos(th), math.sin(th)
        um, vm = n["uMean"], n["vMean"]
        n["uMean"], n["vMean"] = um*ct - vm*st, um*st + vm*ct
        for cc in n["c"].values():
            # A·cos(arg − g) as the phasor A·e^{−ig}: east/north are linear
            # combinations of the U/V phasors, then back to (amp, phase).
            U = cc["uAmp"] * cmath.exp(-1j * math.radians(cc["uPhase"]))
            V = cc["vAmp"] * cmath.exp(-1j * math.radians(cc["vPhase"]))
            E, N = U*ct - V*st, U*st + V*ct
            cc["uAmp"], cc["uPhase"] = abs(E), math.degrees(-cmath.phase(E)) % 360
            cc["vAmp"], cc["vPhase"] = abs(N), math.degrees(-cmath.phase(N)) % 360
    print(f"rotated grid→geographic: {len(grid)} nodes, grid-x angle "
          f"median {math.degrees(med):+.1f}° "
          f"(range {math.degrees(min(known)):+.1f}°..{math.degrees(max(known)):+.1f}°), "
          f"{len(grid)-len(known)} nodes used the median")

if __name__ == "__main__":
    main()
