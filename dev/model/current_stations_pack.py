#!/usr/bin/env python3
"""CHS tidal-current stations → bundled offline current-station predictions.

The SalishSeaCast/WebTide raster models can't resolve the narrow passes (Dodd
Narrows, Gabriola, Seymour Narrows, ...): the channels are narrower than a grid
cell, so the throat is masked as land and the surrounding cells badly understate
the flow (see dev/model-currents-plan.md). CHS publishes point tidal-current
predictions for exactly these passes through the IWLS API. This packs them for
offline use.

HYBRID design (per the feature plan):
  1. Fit the app's 8 astronomical constituents (M2 S2 N2 K2 K1 O1 P1 Q1, the
     same set as TidalHarmonics / current_model.b1) to each station's along-axis
     current, in the *engine's own* Greenwich-phase convention (via tidepredict).
     -> infinite offline forward prediction, reusing the on-device engine.
  2. Also carry each station's exact CHS slack/max EVENTS for a rolling window,
     so displayed slack/max *times* are CHS-exact (the harmonic curve alone is
     ~0.6 kn / ~15 min off CHS for these secondary-station predictions).

Along-axis projection: CHS gives speed + compass direction (flow-toward). A pass
current is rectilinear, so we fit the SIGNED scalar s(t)=speed·cos(dir−flood),
positive on flood (toward floodDirection), negative on ebb. The app rebuilds a
vector from s and the stored flood/ebb axis.

This is a DEV tool (run offline, output committed). Network: IWLS, chunked at 30
days with resolution=FIFTEEN_MINUTES (the API caps undated requests at 7 days).

Usage:
  python3 dev/model/current_stations_pack.py                 # all 22, 1 year
  python3 dev/model/current_stations_pack.py --stations 07487,07545,08108 --days 120
  python3 dev/model/current_stations_pack.py --holdout-days 15
"""
import argparse, datetime as dt, json, math, os, sys, time, urllib.request, urllib.error

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tidepredict as tp

API = "https://api-iwls.dfo-mpo.gc.ca/api/v1"
K = list(tp.CONSTITUENTS)                 # M2 S2 N2 K2 K1 O1 P1 Q1
# App coverage box (ChartBounds.coverage) — only pack passes inside the map.
LATMIN, LATMAX, LONMIN, LONMAX = 46.92, 51.20, -128.23, -122.05


def get(url, tries=4):
    for i in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=90) as r:
                return json.load(r)
        except (urllib.error.URLError, TimeoutError) as e:
            if i == tries - 1:
                raise
            time.sleep(1.5 * (i + 1))


def roster():
    """CHS current-prediction stations (a wcsp* series) inside the coverage box."""
    out = []
    for s in get(f"{API}/stations"):
        codes = {t.get("code", "") for t in (s.get("timeSeries") or [])}
        if not any(c.startswith("wcsp") for c in codes):
            continue
        la, lo = s.get("latitude"), s.get("longitude")
        if la is None or lo is None or not (LATMIN <= la <= LATMAX and LONMIN <= lo <= LONMAX):
            continue
        out.append({"id": s["id"], "code": s["code"], "name": s["officialName"],
                    "lat": la, "lon": lo})
    out.sort(key=lambda s: -s["lat"])
    return out


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch_ts(sid, code, start, end):
    """{epoch_sec: value} for a time-series code over [start,end], 30-day chunks."""
    out = {}
    cur = start
    while cur < end:
        nxt = min(cur + dt.timedelta(days=30), end)
        url = (f"{API}/stations/{sid}/data?time-series-code={code}"
               f"&from={iso(cur)}&to={iso(nxt)}&resolution=FIFTEEN_MINUTES")
        for row in get(url):
            v = row.get("value")
            if v is not None:
                t = dt.datetime.fromisoformat(row["eventDate"].replace("Z", "+00:00"))
                out[int(t.timestamp())] = v
        cur = nxt
    return out


def fetch_events(sid, start, end):
    # The events endpoint caps the range near a year, so chunk (like fetch_ts).
    ev = []
    cur = start
    while cur < end:
        nxt = min(cur + dt.timedelta(days=200), end)
        url = (f"{API}/stations/{sid}/data?time-series-code=wcp1-events"
               f"&from={iso(cur)}&to={iso(nxt)}")
        for row in get(url):
            if row.get("value") is None:
                continue
            t = dt.datetime.fromisoformat(row["eventDate"].replace("Z", "+00:00"))
            ev.append({"t": int(t.timestamp()),
                       "kind": row.get("qualifier", ""), "speed": round(row["value"], 3)})
        cur = nxt
    ev.sort(key=lambda e: e["t"])
    return ev


def station_meta(sid):
    m = get(f"{API}/stations/{sid}/metadata")
    return m.get("floodDirection"), m.get("ebbDirection")


def design_row(dtt):
    """[f·cos(V+u), f·sin(V+u)] per constituent at UTC datetime dtt, engine-exact."""
    a = tp.astro(dtt)
    cols = []
    for name in K:
        f, u = tp.node_factors(name, a["N"])
        arg = math.radians(tp.equilibrium(name, a) + u)
        cols.append(f * math.cos(arg))
        cols.append(f * math.sin(arg))
    return cols


def fit(signed, holdout_days):
    """signed: {epoch: value}. Returns (z0, {name:(amp,phaseDeg)}, holdout_rms, peak)."""
    ts = sorted(signed)
    times = [dt.datetime.fromtimestamp(t, dt.timezone.utc) for t in ts]
    y = np.array([signed[t] for t in ts])
    X = np.array([[1.0] + design_row(d) for d in times])   # [Z0, cos/sin*8]
    cut = ts[-1] - holdout_days * 86400
    tr = np.array([t <= cut for t in ts])
    coef, *_ = np.linalg.lstsq(X[tr], y[tr], rcond=None)
    resid = X[~tr] @ coef - y[~tr]
    rms = float(np.sqrt(np.mean(resid**2))) if resid.size else float("nan")
    cons = {}
    for j, name in enumerate(K):
        p, q = coef[1 + 2 * j], coef[2 + 2 * j]
        cons[name] = (round(float(math.hypot(p, q)), 5),
                      round(float(math.degrees(math.atan2(q, p)) % 360.0), 3))
    return round(float(coef[0]), 5), cons, rms, float(np.max(np.abs(y)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stations", default="", help="comma CHS codes; default all in box")
    ap.add_argument("--days", type=int, default=365, help="fit window length")
    ap.add_argument("--event-days", type=int, default=365, help="slack/max window ahead")
    ap.add_argument("--holdout-days", type=int, default=15)
    ap.add_argument("--out", default=os.path.join(HERE, "current_stations.json"))
    args = ap.parse_args()

    all_st = roster()
    if args.stations:
        want = set(args.stations.split(","))
        all_st = [s for s in all_st if s["code"] in want]
    print(f"stations to pack: {len(all_st)}")

    end = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    start = end - dt.timedelta(days=args.days)              # fit window (past)
    # Events are for PLANNING, so they face the future: a small look-back so a
    # just-passed slack still shows, then a year ahead. (The harmonic curve
    # predicts current speed at any time; only the discrete slack/max events
    # come from this bundled window.)
    ev_start = end - dt.timedelta(days=2)
    ev_end = end + dt.timedelta(days=args.event_days)

    packed = []
    print(f"\n{'name':22} {'code':6} {'flood/ebb':10} {'peak_kn':>7} {'holdout_rms':>11} {'events':>7}")
    for s in all_st:
        flood, ebb = station_meta(s["id"])
        if flood is None:
            print(f"{s['name'][:22]:22} {s['code']:6}  no flood direction — skipped")
            continue
        spd = fetch_ts(s["id"], "wcsp1", start, end)
        drc = fetch_ts(s["id"], "wcdp1", start, end)
        common = sorted(set(spd) & set(drc))
        signed = {t: spd[t] * math.cos(math.radians(drc[t] - flood)) for t in common}
        z0, cons, rms, peak = fit(signed, args.holdout_days)
        events = fetch_events(s["id"], ev_start, ev_end)
        packed.append({"code": s["code"], "name": s["name"], "lat": s["lat"], "lon": s["lon"],
                       "floodDir": flood, "ebbDir": ebb, "z0": z0, "constituents": cons,
                       "holdoutRmsKn": round(rms, 3), "peakKn": round(peak, 2),
                       "events": events})
        print(f"{s['name'][:22]:22} {s['code']:6} {flood:>3}/{ebb:<3}   {peak:7.2f} {rms:11.3f} {len(events):7d}")

    meta = {"stations": len(packed), "constituents": K, "convention": "signed along-axis; value=Z0+Σ f·H·cos(V+u−g); engine=TidalHarmonics",
            "source": "CHS IWLS (api-iwls.dfo-mpo.gc.ca)", "window_days": args.days,
            "holdout_days": args.holdout_days,
            "median_holdout_rms_kn": round(float(np.median([p["holdoutRmsKn"] for p in packed])), 3) if packed else None}
    json.dump({"meta": meta, "stations": packed}, open(args.out, "w"), indent=1)
    print(f"\nwrote {args.out}  ({len(packed)} stations)")
    print(f"median holdout RMS: {meta['median_holdout_rms_kn']} kn")


if __name__ == "__main__":
    main()
