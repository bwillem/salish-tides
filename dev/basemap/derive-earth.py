#!/usr/bin/env python3
"""Rewrite a basemap archive's `earth` layer as the exact complement of its
ocean-water polygons, tile by tile.

Why: the app's styles draw the land fill *above* the ocean fill so the
animated current-particle layer can sit between them (particles over water,
land as a pixel backstop clipping streaks at the drawn coastline — see
standard-{light,dark}.json and MapLibreView.addLayers). That order is only
correct if `earth` is exactly "everything that isn't ocean". The upstream
Protomaps `earth` layer is *not*: it's generalized independently of `water`
at each zoom, aggressively enough that at z8–10 it fills whole channels
(Stuart Channel, Sansum Narrows), which the schema expects the water fill to
paint back in. Drawn above water, that generalization shows as land shards
across navigable water — and it also poisons the particle layer's land mask,
which is built from the rendered earth polygons (visibleFeatures).

Deriving earth = tile□ − union(kind=ocean water) from the same tiles makes
land-above-water render pixel-identical to the schema's water-above-land at
every zoom, with no external data and no coastline disagreement.

Tiles with no earth layer are passed through untouched. Non-ocean water
(lakes, rivers) is ignored here — the styles repaint it above land via the
`water-inland` layer.

Usage:  derive-earth.py IN.pmtiles OUT.pmtiles
Deps :  pip install pmtiles mapbox-vector-tile shapely
"""

import gzip
import json
import os
import sqlite3
import subprocess
import sys
import tempfile

import mapbox_vector_tile as mvt
from pmtiles.reader import MmapSource, Reader, all_tiles
from shapely.geometry import shape, box
from shapely.ops import unary_union

# Protomaps tiles carry geometry out to a 128-unit clip buffer around the
# 4096-unit extent; the derived land must cover the same apron or MapLibre
# would show background-colored seams at tile edges.
BUFFER = 128


def derive(tile_bytes: bytes) -> bytes:
    data = gzip.decompress(tile_bytes) if tile_bytes[:2] == b"\x1f\x8b" else tile_bytes
    tile = mvt.decode(data)
    if "earth" not in tile:
        return tile_bytes

    oceans = []
    for feature in tile.get("water", {}).get("features", []):
        geometry = feature["geometry"]
        if geometry["type"] in ("Polygon", "MultiPolygon") and \
                feature.get("properties", {}).get("kind") == "ocean":
            oceans.append(shape(geometry).buffer(0))

    extent = tile["earth"].get("extent", 4096)
    apron = BUFFER * extent // 4096
    square = box(-apron, -apron, extent + apron, extent + apron)
    land = square.difference(unary_union(oceans)) if oceans else square

    layers = []
    for name, layer in tile.items():
        if name == "earth":
            # Swap the polygons only; the layer's point features (label
            # anchors) pass through for a future labeled style.
            features = [f for f in layer["features"]
                        if f["geometry"]["type"] not in ("Polygon", "MultiPolygon")]
            if not land.is_empty:
                features.append({
                    "geometry": land,
                    "properties": {"kind": "earth"},
                })
        else:
            features = layer["features"]
        layers.append({"name": name, "features": features})

    encoded = mvt.encode(layers, default_options={
        "extents": extent,
        "quantize_bounds": None,
    })
    return gzip.compress(encoded)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-3].strip())
    src_path, dst_path = sys.argv[1], sys.argv[2]

    # Stage through MBTiles and let the go `pmtiles convert` CLI build the
    # final archive: hand-assembled PMTiles directories (python writer) have
    # already burned us — MapLibre failed to load some tiles and silently
    # painted stretched ancestor tiles over the gaps. The CLI produces the
    # same canonical clustered layout as the upstream Protomaps builds.
    with open(src_path, "rb") as f:
        source = MmapSource(f)
        header = Reader(source).header()
        metadata = Reader(source).metadata()

        with tempfile.TemporaryDirectory() as tmp:
            mb_path = os.path.join(tmp, "staged.mbtiles")
            db = sqlite3.connect(mb_path)
            db.execute("CREATE TABLE metadata (name text, value text)")
            db.execute("CREATE TABLE tiles (zoom_level integer, "
                       "tile_column integer, tile_row integer, tile_data blob)")
            db.execute("CREATE UNIQUE INDEX tile_index ON tiles "
                       "(zoom_level, tile_column, tile_row)")
            count = 0
            for (z, x, y), data in all_tiles(source):
                db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)",
                           (z, x, (1 << z) - 1 - y, derive(data)))  # TMS row
                count += 1
            meta = {
                "name": metadata.get("name", "salish"),
                "format": "pbf",
                "minzoom": str(header["min_zoom"]),
                "maxzoom": str(header["max_zoom"]),
                "bounds": ",".join(str(header[k] / 1e7) for k in
                                   ("min_lon_e7", "min_lat_e7",
                                    "max_lon_e7", "max_lat_e7")),
                "center": f'{header["center_lon_e7"]/1e7},'
                          f'{header["center_lat_e7"]/1e7},{header["center_zoom"]}',
                # vector_layers etc. — required by convert for vector tiles.
                "json": json.dumps({k: v for k, v in metadata.items()
                                    if k not in ("name", "format")}),
            }
            db.executemany("INSERT INTO metadata VALUES (?, ?)", meta.items())
            db.commit()
            db.close()

            subprocess.run(["pmtiles", "convert", mb_path, dst_path], check=True)

    print(f"rewrote earth in {count} tiles -> {dst_path}")


if __name__ == "__main__":
    main()
