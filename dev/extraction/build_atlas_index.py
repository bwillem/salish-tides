#!/usr/bin/env python3
"""Generate per-volume atlas_index_vol{N}.json files for viewport region culling.

Each index entry records a chart/region's geographic bounds and vector count so
the app can skip loading regions that don't intersect the visible map area.
Only the `index` array is needed by the app; metadata/regions are omitted for
Vols 2-4 (they aren't read by the culling logic). Run from the repo root.
"""
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(REPO, "data")
RESOURCES = os.path.join(REPO, "SalishTides", "Resources")

VOLUMES = {
    2: "maps_vol2",
    3: "maps_vol3",
    4: "maps_vol4",
}

NAME_RE = re.compile(r"^map_(\d+)_([A-H])\.json$")


def build_index(map_dir):
    entries = []
    for fn in os.listdir(map_dir):
        m = NAME_RE.match(fn)
        if not m:
            continue
        chart, region = int(m.group(1)), m.group(2)
        with open(os.path.join(map_dir, fn)) as f:
            vecs = json.load(f)
        if not vecs:
            continue
        lats = [v["lat"] for v in vecs]
        lons = [v["lon"] for v in vecs]
        entries.append({
            "map_number": chart,
            "region": region,
            "bounds": {
                "lat_min": round(min(lats), 5),
                "lat_max": round(max(lats), 5),
                "lon_min": round(min(lons), 5),
                "lon_max": round(max(lons), 5),
            },
            "vector_count": len(vecs),
        })
    entries.sort(key=lambda e: (e["map_number"], e["region"]))
    return entries


def main():
    for vol, subdir in VOLUMES.items():
        map_dir = os.path.join(DATA, subdir)
        entries = build_index(map_dir)
        out = os.path.join(RESOURCES, f"atlas_index_vol{vol}.json")
        with open(out, "w") as f:
            json.dump({"index": entries}, f, separators=(",", ":"))
        print(f"Vol {vol}: {len(entries)} entries -> {os.path.relpath(out, REPO)}")


if __name__ == "__main__":
    main()
