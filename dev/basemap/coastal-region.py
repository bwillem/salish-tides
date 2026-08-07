#!/usr/bin/env python3
"""Emit the coastal extract region for the offline basemap.

The bundled basemap only needs tiles where the app can draw current arrows —
over water and its immediate shore. A plain lat/lon bbox up to 60°N also sweeps
in the entire BC interior (Dease Lake, Terrace, Smithers, the Coast Mountains):
tile-heavy terrain with no current data under it, inflating the archive for
nothing.

So instead of a rectangle we hand `pmtiles extract` a GeoJSON region built from
the current models' own water footprints:

  * Salish Sea core (`current_model.b1`) → its bounding rectangle. This is the
    primary map area; we want it fully tiled with no interior holes (Vancouver
    Island, the Olympics), so it stays a solid box.

  * Outer coast (`webtide_nepac.b1`) → the model's presence grid, dilated by a
    coastal margin and polygonised. This follows the coastline and open ocean
    (both carry data; ocean tiles are near-empty so cheap) while excluding
    everything more than the margin inland from any modelled water — the
    expensive interior.

Reads the SCTF1 presence bitmaps directly (see dev/model/sctf1.py for the
format). Pure numpy + shapely: the outer grid is dilated by OR-ing shifted
copies, then turned into polygons as per-row rectangle runs and unioned — far
cheaper than buffering 60k points. Writes a GeoJSON Feature (Polygon or
MultiPolygon) in WGS84 lon/lat to the output path.

Usage: coastal-region.py OUT.geojson
"""
import argparse
import json
import struct
import sys

import numpy as np
from shapely import box, unary_union
from shapely.geometry import mapping

RES = "SalishTides/Resources"


def read_sctf1(path):
    d = open(path, "rb").read()
    assert d[:5] == b"SCTF1", f"{path}: not an SCTF1 file"
    off = 5
    rows, cols = struct.unpack_from("<HH", d, off); off += 4
    lat0, lon0, dLat, dLon = struct.unpack_from("<4d", d, off); off += 32
    nConst = d[off]; off += 1
    for _ in range(nConst):
        off += 1 + d[off]
    nbytes = (rows * cols + 7) // 8
    bits = np.frombuffer(d[off:off + nbytes], dtype=np.uint8)
    present = (np.unpackbits(bits, bitorder="little")[:rows * cols]
               .astype(bool).reshape(rows, cols))
    return present, lat0, lon0, dLat, dLon


def dilate(mask, krow, kcol):
    """Square (Chebyshev) dilation by OR-ing zero-filled shifted copies."""
    out = np.zeros_like(mask)
    R, C = mask.shape
    for dy in range(-krow, krow + 1):
        ys0, ys1 = max(0, dy), min(R, R + dy)
        yd0, yd1 = max(0, -dy), min(R, R - dy)
        for dx in range(-kcol, kcol + 1):
            xs0, xs1 = max(0, dx), min(C, C + dx)
            xd0, xd1 = max(0, -dx), min(C, C - dx)
            out[yd0:yd1, xd0:xd1] |= mask[ys0:ys1, xs0:xs1]
    return out


def mask_to_polygon(mask, lat0, lon0, dLat, dLon):
    """Union of per-row rectangle runs of True cells (cell-centred grid)."""
    boxes = []
    hLat, hLon = dLat / 2, dLon / 2
    for r in range(mask.shape[0]):
        row = mask[r]
        if not row.any():
            continue
        edges = np.diff(np.concatenate([[0], row.view(np.int8), [0]]))
        starts = np.where(edges == 1)[0]
        ends = np.where(edges == -1)[0]
        y = lat0 + r * dLat
        for c0, c1 in zip(starts, ends):
            x_lo = lon0 + c0 * dLon - hLon
            x_hi = lon0 + (c1 - 1) * dLon + hLon
            boxes.append(box(x_lo, y - hLat, x_hi, y + hLat))
    return unary_union(boxes)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    # ~0.12° (~13 km) coastal margin on the outer grid: enough to bridge the
    # 0.036°×0.060° cell spacing into continuous coverage and keep the shoreline,
    # short of reaching inland towns up the long inlets.
    ap.add_argument("--margin-deg", type=float, default=0.12)
    ap.add_argument("--simplify", type=float, default=0.02)
    args = ap.parse_args()

    # Outer coast: dilate the presence grid and polygonise.
    pres, lat0, lon0, dLat, dLon = read_sctf1(f"{RES}/webtide_nepac.b1")
    krow = max(1, round(args.margin_deg / abs(dLat)))
    kcol = max(1, round(args.margin_deg / abs(dLon)))
    print(f"webtide {pres.shape} water={pres.sum()} dilate k=({krow},{kcol})",
          file=sys.stderr)
    outer = mask_to_polygon(dilate(pres, krow, kcol), lat0, lon0, dLat, dLon)

    # Salish core: solid bounding rectangle (no interior holes in the main area).
    sp, sla0, slo0, sdLat, sdLon = read_sctf1(f"{RES}/current_model.b1")
    ys, xs = np.nonzero(sp)
    salish = box(slo0 + xs.min() * sdLon, sla0 + ys.min() * sdLat,
                 slo0 + xs.max() * sdLon, sla0 + ys.max() * sdLat)

    region = unary_union([outer, salish])
    if args.simplify > 0:
        region = region.simplify(args.simplify).buffer(0)

    polys = list(region.geoms) if region.geom_type == "MultiPolygon" else [region]
    nverts = sum(len(p.exterior.coords) for p in polys)
    print(f"region: {len(polys)} polygons, {nverts} vertices, "
          f"area {region.area:.1f} deg^2 (bbox rect would be "
          f"{(60.05-45.9)*(140.1-121.9):.1f})", file=sys.stderr)

    with open(args.out, "w") as f:
        json.dump({"type": "Feature", "properties": {},
                   "geometry": mapping(region)}, f)
    print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
