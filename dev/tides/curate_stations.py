#!/usr/bin/env python3
"""Curate the Salish Sea tide-station registry for Salish Tides.

Pulls the live station lists from NOAA CO-OPS (US) and CHS IWLS (Canada),
keeps only stations that actually publish tide PREDICTIONS, restricts to the
four atlas-volume bounds, and spatially thins to a target spacing so coverage
is even without carrying redundant clustered ports.

Output: dev/tides/stations_2026.json  — the registry consumed by fetch_tides.py.

The three atlas reference stations (Point Atkinson, Seattle, Powell River) are
force-kept as anchors regardless of thinning.

Usage:
    python3 curate_stations.py [--spacing-km 12]
"""
import argparse
import json
import math
import os
import urllib.request

# Atlas volume bounds (mirrors SalishTides/Models/AtlasVolume.swift).
# A station is "atlas-relevant" if it falls within at least one volume box.
VOLUMES = [
    ("Vol1", 47.9, 49.5, -124.0, -122.3),  # Strait of Georgia / Gulf Islands
    ("Vol2", 46.9, 48.5, -123.9, -122.1),  # Puget Sound / S. Juan de Fuca
    ("Vol3", 49.0, 51.0, -126.1, -124.0),  # Desolation Sound
    ("Vol4", 49.8, 52.2, -129.1, -125.0),  # Johnstone St. / N. Strait of Georgia
]
PAD = 0.05  # degrees of slop so edge stations aren't dropped

# Atlas timing references, matched by name (see *_lookup_*.json reference_station).
REFERENCE_NAMES = ("point atkinson", "seattle", "powell river")

NOAA_URL = ("https://api.tidesandcurrents.noaa.gov/mdapi/prod/webapi/"
            "stations.json?type=tidepredictions")
CHS_URL = "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations"


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "salish-tides-curate"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def _vols_for(lat, lon):
    return [n for n, la, lb, oa, ob in VOLUMES
            if la - PAD <= lat <= lb + PAD and oa - PAD <= lon <= ob + PAD]


def _km(a, b):
    R = 6371.0
    la1, lo1, la2, lo2 = map(math.radians, [a["lat"], a["lon"], b["lat"], b["lon"]])
    h = (math.sin((la2 - la1) / 2) ** 2
         + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * R * math.asin(math.sqrt(h))


def _is_reference(name):
    return any(r in (name or "").lower() for r in REFERENCE_NAMES)


def collect():
    out = []

    # NOAA — every type=tidepredictions station publishes predictions.
    # Datum: MLLW. kind R=harmonic/reference, S=subordinate(offset).
    for s in _get(NOAA_URL)["stations"]:
        vols = _vols_for(s["lat"], s["lng"])
        if not vols:
            continue
        out.append({
            "src": "NOAA", "id": str(s["id"]), "name": s["name"],
            "lat": round(s["lat"], 4), "lon": round(s["lng"], 4),
            "datum": "MLLW", "kind": s.get("type", ""), "vols": vols,
            "is_reference": _is_reference(s["name"]),
        })

    # CHS — keep only stations exposing 'wlp' (water level predictions);
    # 'wlo'-only stations are observation gauges with no published tides.
    # Datum: Chart Datum (CD).
    for s in _get(CHS_URL):
        lat, lon = s.get("latitude"), s.get("longitude")
        if lat is None or lon is None:
            continue
        codes = {ts.get("code") for ts in s.get("timeSeries", [])}
        if "wlp" not in codes and "wlp-hilo" not in codes:
            continue
        vols = _vols_for(lat, lon)
        if not vols:
            continue
        out.append({
            "src": "CHS", "id": s.get("code"), "chs_id": s.get("id"),
            "name": s.get("officialName"),
            "lat": round(lat, 4), "lon": round(lon, 4),
            "datum": "CD", "kind": "wlp", "vols": vols,
            "is_reference": _is_reference(s.get("officialName")),
        })

    return out


def thin(stations, min_km):
    """Greedy spatial thinning. Anchors and NOAA harmonic stations win ties;
    drop any candidate within min_km of an already-kept station."""
    order = sorted(stations, key=lambda s: (
        not s["is_reference"], s["kind"] != "R", s["name"] or ""))
    kept = []
    for s in order:
        if all(_km(s, k) >= min_km for k in kept):
            kept.append(s)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spacing-km", type=float, default=12.0,
                    help="minimum inter-station spacing (default 12)")
    args = ap.parse_args()

    raw = collect()
    kept = thin(raw, args.spacing_km)
    kept.sort(key=lambda s: (s["vols"][0], s["src"], s["name"] or ""))

    here = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(here, "stations_2026.json")
    json.dump({
        "year": 2026,
        "spacing_km": args.spacing_km,
        "count": len(kept),
        "stations": kept,
    }, open(out_path, "w"), indent=2)

    per_vol = {v: sum(v in s["vols"] for s in kept)
               for v, *_ in VOLUMES}
    print(f"raw prediction stations in atlas bounds: {len(raw)}")
    print(f"after {args.spacing_km} km thinning:        {len(kept)}")
    print(f"  NOAA {sum(s['src']=='NOAA' for s in kept)}, "
          f"CHS {sum(s['src']=='CHS' for s in kept)}")
    print(f"  per volume: {per_vol}")
    print(f"  anchors kept: "
          f"{[s['name'] for s in kept if s['is_reference']]}")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
