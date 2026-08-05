#!/usr/bin/env python3
"""SCST1 — the packed CHS current-station asset (constants + slack/max events).

Sibling to sctf1 (the gridded SCTF1 model): that format is a regular lat/lon
mesh; current stations are a handful of points, so they get their own compact
little-endian layout. One file ships as SalishTides/Resources/current_stations.b1
and is decoded by SalishTides/CurrentModel/CurrentStations.swift.

Layout (little-endian):
  magic  b"SCST1"
  u8     nConst           # constituent count (8: M2 S2 N2 K2 K1 O1 P1 Q1)
  nConst × (u8 len + ascii name)     # asserted == TidalHarmonics order on decode
  u16    stationCount
  per station:
    u8 len + ascii  code             # CHS station code, e.g. "07487"
    u8 len + utf8   name             # "Dodd Narrows"
    f64 lat, f64 lon
    f32 floodDir, f32 ebbDir         # compass bearing current flows TOWARD (deg)
    f32 z0                           # mean along-axis current (knots)
    nConst × (f32 amp, f32 phaseDeg) # signed along-axis: Σ f·amp·cos(V+u − phase)
    u32 eventCount
    eventCount × (u32 epochSec, u8 kind, f32 speedKn)   # kind 0 slack / 1 flood / 2 ebb
"""
import struct

MAGIC = b"SCST1"
KINDS = {"SLACK": 0, "EXTREMA_FLOOD": 1, "EXTREMA_EBB": 2}
KIND_NAME = {v: k for k, v in KINDS.items()}


def _pstr(s):
    b = s.encode("utf-8")
    assert len(b) < 256, f"string too long: {s!r}"
    return struct.pack("<B", len(b)) + b


def write(path, constituents, stations):
    """stations: list of dicts as emitted by current_stations_pack.py."""
    out = bytearray(MAGIC)
    out += struct.pack("<B", len(constituents))
    for nm in constituents:
        out += _pstr(nm)
    out += struct.pack("<H", len(stations))
    for s in stations:
        out += _pstr(s["code"])
        out += _pstr(s["name"])
        out += struct.pack("<dd", s["lat"], s["lon"])
        out += struct.pack("<fff", s["floodDir"], s["ebbDir"], s["z0"])
        for nm in constituents:
            amp, pha = s["constituents"][nm]
            out += struct.pack("<ff", amp, pha)
        ev = s["events"]
        out += struct.pack("<I", len(ev))
        for e in ev:
            out += struct.pack("<IBf", int(e["t"]), KINDS.get(e["kind"], 0), e["speed"])
    with open(path, "wb") as f:
        f.write(out)
    return len(out)


def read(path):
    """Inverse of write() — used by the verify self-check."""
    b = open(path, "rb").read()
    assert b[:5] == MAGIC, "bad magic"
    o = 5
    (nConst,) = struct.unpack_from("<B", b, o); o += 1
    names = []
    for _ in range(nConst):
        (ln,) = struct.unpack_from("<B", b, o); o += 1
        names.append(b[o:o+ln].decode()); o += ln
    (nSt,) = struct.unpack_from("<H", b, o); o += 2
    stations = []
    for _ in range(nSt):
        def rstr(o):
            (ln,) = struct.unpack_from("<B", b, o); o += 1
            return b[o:o+ln].decode("utf-8"), o + ln
        code, o = rstr(o)
        name, o = rstr(o)
        lat, lon = struct.unpack_from("<dd", b, o); o += 16
        flood, ebb, z0 = struct.unpack_from("<fff", b, o); o += 12
        cons = {}
        for nm in names:
            amp, pha = struct.unpack_from("<ff", b, o); o += 8
            cons[nm] = (amp, pha)
        (nEv,) = struct.unpack_from("<I", b, o); o += 4
        ev = []
        for _ in range(nEv):
            t, kind, spd = struct.unpack_from("<IBf", b, o); o += 9
            ev.append({"t": t, "kind": KIND_NAME.get(kind, "?"), "speed": spd})
        stations.append(dict(code=code, name=name, lat=lat, lon=lon,
                             floodDir=flood, ebbDir=ebb, z0=z0,
                             constituents=cons, events=ev))
    return names, stations
