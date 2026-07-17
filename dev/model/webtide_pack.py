#!/usr/bin/env python3
"""WebTide ne_pac4 → webtide_nepac.b1: the NE Pacific offline current model,
packed as a SECOND SCTF1 asset alongside current_model.b1.

Why a separate file (vs merging both sources into one asset): the two
sources want different grid resolutions — SalishSeaCast is native ~500 m,
WebTide's finite-element mesh is 2–12 km — and one regular grid can't serve
both without either gigabytes of oversampling or degrading the Salish Sea.
The app decodes both files with the same OfflineCurrentModel and simply
concatenates their vectors.

SalishSeaCast priority is baked in HERE, at pack time: every grid cell whose
centre lies within --mask-km of any SSC water node (decoded from the shipped
current_model.b1) is dropped, so the two assets are spatially disjoint and the
app needs zero overlap logic. Re-run this packer whenever current_model.b1 is
repacked — the meta json records the SSC file's sha256 to catch a mismatch.

Interpolation: barycentric over WebTide's own FE triangulation, per-constituent u/v as COMPLEX phasors
A·e^{-i g} (never raw amplitude/degrees, which would wrap), water-masked for
free because the mesh only triangulates water. uMean/vMean are 0 — WebTide is
pure tidal, no residual.

LICENSE: WebTide's redistribution terms are pending DFO/BIO sign-off (see
webtide_fetch.py). Do not SHIP a build containing the output until resolved.

Usage:
  python3 dev/model/webtide_pack.py [--km 4.0] [--mask-km 2.4]
      [--clip lonmin,latmin,lonmax,latmax]     # default WA coast → SE Alaska
      [--src dev/model/webtide/ne_pac4]
      [--ssc SalishTides/Resources/current_model.b1]
      [--out SalishTides/Resources/webtide_nepac.b1]
"""
import argparse, hashlib, json, math, os, struct, sys

import numpy as np
from scipy.spatial import cKDTree
from matplotlib.tri import Triangulation

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tidepredict import CONSTITUENTS

K = list(CONSTITUENTS)                      # M2 S2 N2 K2 K1 O1 P1 Q1
REC = 2 + 4 * len(K)


def decode_b1(path):
    """SCTF1 → (lat[N], lon[N], coeffs[N,REC]). Shared with the validator."""
    buf = open(path, "rb").read()
    assert buf[:5] == b"SCTF1", "bad magic"
    rows, cols = struct.unpack_from("<HH", buf, 5)
    lat0, lon0, dLat, dLon = struct.unpack_from("<dddd", buf, 9)
    o = 41
    nC = buf[o]; o += 1
    names = []
    for _ in range(nC):
        ln = buf[o]; o += 1
        names.append(buf[o:o+ln].decode()); o += ln
    assert names == K, f"constituent set differs: {names} != {K}"
    nbits = rows * cols
    bmp = buf[o:o + (nbits + 7)//8]; o += (nbits + 7)//8
    lats, lons, coeffs = [], [], []
    p = o
    for i in range(nbits):
        if (bmp[i >> 3] >> (i & 7)) & 1:
            r, c = divmod(i, cols)
            lats.append(lat0 + r*dLat); lons.append(lon0 + c*dLon)
            coeffs.append(struct.unpack_from(f"<{REC}f", buf, p)); p += REC*4
    return (np.array(lats), np.array(lons), np.array(coeffs, np.float64),
            (rows, cols, lat0, lon0, dLat, dLon))


def load_webtide_raw(src):
    """Full ne_pac4 mesh → (lat[N], lon[N], tris[M,3] 0-based,
    Cu[N,K] complex, Cv[N,K] complex). Complex = A·e^{-i g} (matches the
    decoder's u = uMean + Σ A·cos(arg − g))."""
    ids = []; lat = []; lon = []
    with open(os.path.join(src, "ne_pac4_ll.nod")) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3:
                ids.append(int(p[0])); lon.append(float(p[1])); lat.append(float(p[2]))
    id2idx = {i: k for k, i in enumerate(ids)}
    N = len(ids)
    lat = np.array(lat); lon = np.array(lon)

    tris = []
    with open(os.path.join(src, "ne_pac4.ele")) as f:
        for line in f:
            p = line.split()
            if len(p) >= 4:
                try:
                    tris.append((id2idx[int(p[1])], id2idx[int(p[2])], id2idx[int(p[3])]))
                except KeyError:
                    continue
    tris = np.array(tris, np.int64)

    Cu = np.zeros((N, len(K)), np.complex128)
    Cv = np.zeros((N, len(K)), np.complex128)
    for j, nm in enumerate(K):
        with open(os.path.join(src, f"{nm}.barotropic.v2c")) as f:
            for k, line in enumerate(f):
                if k < 3:
                    continue
                p = line.split()
                if len(p) >= 5:
                    idx = id2idx.get(int(p[0]))
                    if idx is None:
                        continue
                    uA, uP, vA, vP = (float(x) for x in p[1:5])
                    Cu[idx, j] = uA * np.exp(-1j*math.radians(uP))
                    Cv[idx, j] = vA * np.exp(-1j*math.radians(vP))
    print(f"loaded WebTide: {N} nodes, {len(tris)} triangles  "
          f"lat {lat.min():.2f}..{lat.max():.2f} lon {lon.min():.2f}..{lon.max():.2f}")
    return lat, lon, tris, Cu, Cv


def barycentric(px, py, x0, y0, x1, y1, x2, y2):
    den = (y1-y2)*(x0-x2) + (x2-x1)*(y0-y2)
    w0 = ((y1-y2)*(px-x2) + (x2-x1)*(py-y2)) / den
    w1 = ((y2-y0)*(px-x2) + (x0-x2)*(py-y2)) / den
    return w0, w1, 1.0 - w0 - w1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(HERE, "webtide", "ne_pac4"))
    ap.add_argument("--ssc", default=os.path.join(HERE, "..", "..",
                    "SalishTides/Resources/current_model.b1"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..",
                    "SalishTides/Resources/webtide_nepac.b1"))
    ap.add_argument("--km", type=float, default=4.0, help="grid spacing (km)")
    ap.add_argument("--mask-km", type=float, default=None,
                    help="drop cells within this of an SSC water node "
                         "(default 0.6*km)")
    # WA coast → SE Alaska incl. Haida Gwaii. WebTide itself bounds the west/
    # offshore extent (no triangles → no cells), the clip bounds the rest.
    ap.add_argument("--clip", default="-140.0,46.0,-122.0,60.0",
                    help="lonmin,latmin,lonmax,latmax")
    args = ap.parse_args()
    mask_km = args.mask_km if args.mask_km is not None else 0.6 * args.km
    clon0, clat0, clon1, clat1 = (float(x) for x in args.clip.split(","))

    sla, slo, ssc_coeffs, _ = decode_b1(args.ssc)
    ssc_sha = hashlib.sha256(open(args.ssc, "rb").read()).hexdigest()
    print(f"decoded SSC mask source: {len(sla)} nodes  "
          f"lat {sla.min():.2f}..{sla.max():.2f} lon {slo.min():.2f}..{slo.max():.2f}")
    wla, wlo, wtris, Cu, Cv = load_webtide_raw(args.src)

    # Clip (+1° margin) BEFORE triangulating: the raw mesh is global and its
    # far-field / antimeridian triangles make matplotlib's trifinder reject
    # the whole mesh as invalid.
    m = 1.0
    nmask = ((wlo >= clon0-m) & (wlo <= clon1+m) &
             (wla >= clat0-m) & (wla <= clat1+m))
    remap = np.full(len(wlo), -1, np.int64)
    remap[nmask] = np.arange(int(nmask.sum()))
    tmask = nmask[wtris].all(axis=1)
    wtris = remap[wtris[tmask]]
    wla, wlo, Cu, Cv = wla[nmask], wlo[nmask], Cu[nmask], Cv[nmask]
    print(f"clipped to region: {len(wla)} nodes, {len(wtris)} triangles")

    # Regular grid at --km over the clip box.
    latmid = 0.5*(clat0+clat1)
    DLAT = args.km/111.0
    DLON = args.km/(111.0*math.cos(math.radians(latmid)))
    lat0 = math.floor(clat0/DLAT)*DLAT
    lon0 = math.floor(clon0/DLON)*DLON
    rows = int(math.ceil((clat1-lat0)/DLAT))+1
    cols = int(math.ceil((clon1-lon0)/DLON))+1
    assert rows <= 65535 and cols <= 65535, "grid exceeds UInt16 header"
    ncell = rows*cols
    print(f"grid: {rows}x{cols} = {ncell} cells at {args.km} km "
          f"(dLat {DLAT:.5f} dLon {DLON:.5f})")

    mr, mc = np.meshgrid(np.arange(rows), np.arange(cols), indexing="ij")
    mlat = lat0 + mr.ravel()*DLAT
    mlon = lon0 + mc.ravel()*DLON

    # Barycentric phasor interpolation over the FE triangulation. Cells
    # outside every triangle (land, beyond the mesh) get no value.
    tri = Triangulation(wlo, wla, wtris)
    finder = tri.get_trifinder()
    tidx = finder(mlon, mlat)
    ok = tidx >= 0
    cells = np.where(ok)[0]; tsel = tidx[ok]
    print(f"in-mesh: {len(cells)} cells")

    # SSC priority mask, in km-scaled coordinates.
    def scale(la, lo):
        return np.column_stack([(la-latmid)*111.0,
                                (lo-lon0)*111.0*math.cos(math.radians(latmid))])
    ssc_tree = cKDTree(scale(sla, slo))
    dist, _ = ssc_tree.query(scale(mlat[cells], mlon[cells]))
    keep = dist >= mask_km
    masked = int((~keep).sum())
    cells = cells[keep]; tsel = tsel[keep]
    print(f"masked {masked} cells within {mask_km:.2f} km of SSC water "
          f"→ {len(cells)} kept")

    tn = wtris[tsel]
    x = wlo[tn]; y = wla[tn]
    w0, w1, w2 = barycentric(mlon[cells], mlat[cells],
                             x[:, 0], y[:, 0], x[:, 1], y[:, 1], x[:, 2], y[:, 2])
    w0 = w0[:, None]; w1 = w1[:, None]; w2 = w2[:, None]
    Cu_i = w0*Cu[tn[:, 0]] + w1*Cu[tn[:, 1]] + w2*Cu[tn[:, 2]]
    Cv_i = w0*Cv[tn[:, 0]] + w1*Cv[tn[:, 1]] + w2*Cv[tn[:, 2]]
    uAmp = np.abs(Cu_i); uPha = np.degrees(-np.angle(Cu_i)) % 360.0
    vAmp = np.abs(Cv_i); vPha = np.degrees(-np.angle(Cv_i)) % 360.0

    block = np.empty((len(cells), REC), np.float32)
    block[:, 0] = 0.0; block[:, 1] = 0.0               # uMean, vMean
    for j in range(len(K)):
        b = 2 + 4*j
        block[:, b] = uAmp[:, j]; block[:, b+1] = uPha[:, j]
        block[:, b+2] = vAmp[:, j]; block[:, b+3] = vPha[:, j]
    assert np.isfinite(block).all(), "non-finite coefficients"

    present = np.zeros(ncell, bool)
    present[cells] = True
    coeff = np.zeros((ncell, REC), np.float32)
    coeff[cells] = block

    out = os.path.normpath(args.out)
    with open(out, "wb") as f:
        f.write(b"SCTF1")
        f.write(struct.pack("<HH", rows, cols))
        f.write(struct.pack("<dddd", lat0, lon0, DLAT, DLON))
        f.write(struct.pack("<B", len(K)))
        for nm in K:
            bb = nm.encode("ascii"); f.write(struct.pack("<B", len(bb))); f.write(bb)
        # LSB-first within each byte: decoder reads bits[i>>3] & (1<<(i&7)).
        f.write(np.packbits(present, bitorder="little").tobytes())
        f.write(coeff[present].tobytes())
    sz = os.path.getsize(out)
    print(f"wrote {out}  ({sz/1e6:.2f} MB, {len(cells)} nodes)")

    # ---- self-validation: independent re-read of what we just wrote ----
    vla, vlo, vco, vhdr = decode_b1(out)
    assert vhdr == (rows, cols, lat0, lon0, DLAT, DLON), "header mismatch"
    assert len(vla) == len(cells), "node count mismatch"
    rng = np.random.default_rng(0)
    for i in rng.choice(len(cells), size=min(200, len(cells)), replace=False):
        assert np.allclose(vco[i], block[i].astype(np.float64), atol=0), \
            f"coeff mismatch at node {i}"
    # Overlap assert: the shipped pair must be spatially disjoint.
    vdist, _ = ssc_tree.query(scale(vla, vlo))
    assert vdist.min() >= mask_km, \
        f"overlap: WebTide node {vdist.min():.2f} km from SSC water (< {mask_km})"
    print(f"validated: 200-cell byte compare OK, min distance to SSC "
          f"{vdist.min():.2f} km (mask {mask_km:.2f})")

    meta = {
        "rows": rows, "cols": cols, "lat0": lat0, "lon0": lon0,
        "dLat": DLAT, "dLon": DLON, "constituents": K,
        "nodes": int(len(cells)), "masked_cells": masked,
        "km": args.km, "mask_km": mask_km,
        "clip": [clon0, clat0, clon1, clat1],
        "source": "DFO WebTide ne_pac4 (barotropic)", "frame": "geographic",
        "ssc_file_sha256": ssc_sha, "bytes": sz,
    }
    meta_path = os.path.join(HERE, "webtide_nepac.b1.meta.json")
    json.dump(meta, open(meta_path, "w"), indent=2)
    print(f"wrote {meta_path}")


if __name__ == "__main__":
    main()
