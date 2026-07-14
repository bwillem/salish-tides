#!/usr/bin/env python3
"""Direction validation of the PACKED current_model.b1 against the Dewey atlas
(whole-domain, not just the PoC box). Mirrors what the review measured:
before the rotation fix, signed median direction error was ~-30 deg."""
import sys, json, glob, math, struct
sys.path.insert(0, "dev/model")
import numpy as np
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from tidepredict import astro, node_factors, equilibrium, CONSTITUENTS

BIN = "SalishTides/Resources/current_model.b1"
K = list(CONSTITUENTS)
UTC, LOCAL = ZoneInfo("UTC"), ZoneInfo("America/Vancouver")

# --- parse the packed asset --------------------------------------------------
buf = open(BIN, "rb").read()
assert buf[:5] == b"SCTF1"
rows, cols = struct.unpack_from("<HH", buf, 5)
lat0, lon0, dLat, dLon = struct.unpack_from("<dddd", buf, 9)
o = 41
(nc,) = struct.unpack_from("<B", buf, o); o += 1
names = []
for _ in range(nc):
    (ln,) = struct.unpack_from("<B", buf, o); o += 1
    names.append(buf[o:o+ln].decode()); o += ln
assert names == K
bm_off = o; o += (rows * cols + 7) // 8
rec = 4 * (2 + 4 * nc)
present = np.array([(buf[bm_off + (i >> 3)] >> (i & 7)) & 1 for i in range(rows * cols)], bool)
ordinal = np.cumsum(present) - 1

def node_coeffs(r, c):
    i = r * cols + c
    if not (0 <= r < rows and 0 <= c < cols and present[i]):
        return None
    return struct.unpack_from(f"<{2 + 4*nc}f", buf, o + int(ordinal[i]) * rec)

def predict_uv(coeffs, t):
    a = astro(t)
    u, v = coeffs[0], coeffs[1]
    for ki, nm in enumerate(K):
        f, nu = node_factors(nm, a["N"])
        arg = math.radians(equilibrium(nm, a) + nu)
        base = 2 + 4 * ki
        u += f * coeffs[base]     * math.cos(arg - math.radians(coeffs[base+1]))
        v += f * coeffs[base + 2] * math.cos(arg - math.radians(coeffs[base+3]))
    return u, v

# --- atlas lookup (all volumes, whole domain) --------------------------------
lut = json.load(open("SalishTides/Resources/atlas_lookup_2026.json"))
def atlas_chart(tl):
    row = lut["grid"].get(str(tl.month), {}).get(str(tl.day))
    return None if not row or tl.hour >= len(row) else row[tl.hour]

_cache = {}
def atlas_arrows(chart):
    if chart not in _cache:
        pts = []
        for f in glob.glob(f"data/maps/map_{chart}_*.json"):
            pts.extend(json.load(open(f)))
        _cache[chart] = pts
    return _cache[chart]

def wrap180(x): return (x + 180) % 360 - 180

day = datetime(2026, 6, 15, 0, 0, tzinfo=LOCAL)
signed, absd, n = [], [], 0
for h in range(24):
    tl = day + timedelta(hours=h)
    chart = atlas_chart(tl)
    if chart is None:
        continue
    tu = tl.astimezone(UTC)
    for a in atlas_arrows(chart):
        if a["speed_ms"] <= 0.15:
            continue
        r = round((a["lat"] - lat0) / dLat)
        c = round((a["lon"] - lon0) / dLon)
        coeffs = node_coeffs(r, c)
        if coeffs is None:
            continue
        u, v = predict_uv(coeffs, tu)
        spd = math.hypot(u, v)
        if spd <= 0.15:
            continue
        d = math.degrees(math.atan2(u, v)) % 360
        n += 1
        signed.append(wrap180(d - a["direction_deg"]))
        absd.append(abs(wrap180(d - a["direction_deg"])))

s, ad = np.array(signed), np.array(absd)
print(f"packed model vs atlas, {n} arrow-hours (both >0.15 m/s), Vol 1 day 2026-06-15:")
print(f"  signed direction error: median {np.median(s):+.1f} deg  mean {s.mean():+.1f} deg")
print(f"  |direction error|: median {np.median(ad):.1f} deg  90th {np.percentile(ad,90):.1f} deg")
print(f"  flips >90 deg: {100*np.mean(ad>90):.1f}%")
