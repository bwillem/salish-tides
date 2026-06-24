#!/usr/bin/env python3
"""Fetch 2026 hi/lo tide predictions for the curated Salish Sea station registry.

Reads dev/tides/stations_2026.json, pulls a full year of high/low tide events for
each station from its source API, and writes the bundled dataset to
data/tides/tides_2026.json (consumed by the SQLite migration).

Sources & conventions:
  - NOAA CO-OPS  : datagetter, interval=hilo, datum=MLLW, units=metric, time_zone=gmt.
                   Returns H/L type directly.
  - CHS IWLS     : /stations/{chs_id}/data?time-series-code=wlp-hilo (datum = Chart Datum).
                   No H/L label -> derived here from local extrema (events alternate).
  - All times stored as ISO-8601 UTC; the app converts to America/Vancouver for display.
  - Heights in metres, rounded to 2 dp. Per-station datum is preserved (MLLW vs CD,
    never merged).

Events are stored compactly as [iso_utc, height, "H"|"L"].

Usage:
    python3 fetch_tides.py [--limit N] [--resume] [--year 2026]
"""
import argparse
import datetime as dt
import json
import os
import time
import urllib.error
import urllib.request

NOAA_FMT = (
    "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"
    "?product=predictions&application=salish-tides&interval=hilo"
    "&datum=MLLW&units=metric&time_zone=gmt&format=json"
    "&begin_date={begin}&end_date={end}&station={sid}"
)
CHS_FMT = (
    "https://api-iwls.dfo-mpo.gc.ca/api/v1/stations/{sid}/data"
    "?time-series-code=wlp-hilo&from={begin}&to={end}"
)

HERE = os.path.dirname(os.path.abspath(__file__))
REGISTRY = os.path.join(HERE, "stations_2026.json")


def _fetch(url, attempts=3):
    last = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "salish-tides-fetch"})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
            last = e
            time.sleep(1.5 * (i + 1))
    raise last


def fetch_noaa(sid, begin, end):
    url = NOAA_FMT.format(begin=begin.strftime("%Y%m%d"),
                          end=end.strftime("%Y%m%d"), sid=sid)
    d = _fetch(url)
    preds = d.get("predictions")
    if not preds:
        raise RuntimeError(f"NOAA {sid}: {d.get('error', 'no predictions')}")
    events = []
    for p in preds:
        # "2026-01-01 02:36" GMT -> ISO UTC
        iso = p["t"].replace(" ", "T") + ":00Z"
        events.append([iso, round(float(p["v"]), 2), p["type"]])
    return events


def fetch_chs(chs_id, begin, end):
    url = CHS_FMT.format(
        sid=chs_id,
        begin=begin.strftime("%Y-%m-%dT00:00:00Z"),
        end=end.strftime("%Y-%m-%dT23:59:59Z"),
    )
    d = _fetch(url)
    if not isinstance(d, list) or not d:
        raise RuntimeError(f"CHS {chs_id}: empty/unexpected response")
    raw = [(e["eventDate"], round(float(e["value"]), 2)) for e in d]
    return _label_hilo(raw)


def _label_hilo(raw):
    """Classify each (time, height) extremum as High or Low.

    hi/lo predictions strictly alternate, so a point is High when its height is
    >= both neighbours and Low when <= both. Endpoints use their single neighbour."""
    n = len(raw)
    out = []
    for i, (t, h) in enumerate(raw):
        prev_h = raw[i - 1][1] if i > 0 else None
        next_h = raw[i + 1][1] if i < n - 1 else None
        ref = next_h if prev_h is None else prev_h
        out.append([t, h, "H" if h >= ref else "L"])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", type=int, default=2026)
    ap.add_argument("--limit", type=int, default=0, help="fetch only first N stations (testing)")
    ap.add_argument("--resume", action="store_true", help="skip stations already in output")
    args = ap.parse_args()

    reg = json.load(open(REGISTRY))
    stations = reg["stations"]
    if args.limit:
        stations = stations[:args.limit]

    begin = dt.date(args.year, 1, 1)
    end = dt.date(args.year, 12, 31)

    out_dir = os.path.join(HERE, "..", "..", "data", "tides")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"tides_{args.year}.json")

    done = {}
    if args.resume and os.path.exists(out_path):
        prev = json.load(open(out_path))
        done = {s["key"]: s for s in prev.get("stations", [])}
        print(f"resume: {len(done)} stations already fetched")

    results, failures = [], []
    for i, s in enumerate(stations, 1):
        key = f"{s['src']}:{s['id']}"
        if key in done:
            results.append(done[key])
            continue
        try:
            if s["src"] == "NOAA":
                events = fetch_noaa(s["id"], begin, end)
            else:
                events = fetch_chs(s["chs_id"], begin, end)
            results.append({
                "key": key, "src": s["src"], "id": s["id"], "name": s["name"],
                "lat": s["lat"], "lon": s["lon"], "datum": s["datum"],
                "vols": s["vols"], "events": events,
            })
            print(f"[{i:3d}/{len(stations)}] {key:14s} {len(events):4d} events  {s['name']}")
        except Exception as e:  # noqa: BLE001 — record and continue
            failures.append((key, s["name"], str(e)))
            print(f"[{i:3d}/{len(stations)}] {key:14s} FAILED: {e}")
        time.sleep(0.2)  # be polite

    results.sort(key=lambda r: (r["vols"][0], r["src"], r["name"] or ""))
    json.dump({
        "year": args.year,
        "generated": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "datums": {"NOAA": "MLLW", "CHS": "CD"},
        "station_count": len(results),
        "stations": results,
    }, open(out_path, "w"), separators=(",", ":"))

    size_mb = os.path.getsize(out_path) / 1e6
    print(f"\nwrote {out_path}  ({len(results)} stations, {size_mb:.1f} MB)")
    if failures:
        print(f"\n{len(failures)} FAILURES (re-run with --resume to retry):")
        for k, name, err in failures:
            print(f"  {k}  {name}: {err}")


if __name__ == "__main__":
    main()
