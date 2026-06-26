#!/usr/bin/env python3
"""B1 PoC de-risk: confirm utide's fitted constituents are compatible with our
predictor's convention. Generate a year-long signal with our predictor from
known constituents, fit it with utide, then reconstruct with our predictor
using utide's recovered amp/phase. High skill ⇒ utide → our-predictor path is
sound (so utide-derived current constituents will drive the Swift predictor)."""
import sys; sys.path.insert(0, "dev/model")
from tidepredict import predict, CONSTITUENTS
import numpy as np, json
from datetime import datetime, timezone, timedelta
import utide

ref = json.load(open("dev/model/noaa_seattle_ref.json"))
cons = [c for c in ref["constituents"] if c["name"] in CONSTITUENTS]
names = [c["name"] for c in cons]

t0 = datetime(2023, 1, 1, 0, 30, tzinfo=timezone.utc)
times = [t0 + timedelta(hours=i) for i in range(8760)]      # 1 yr hourly
sig = np.array([predict(cons, t) for t in times])           # our-predictor truth
t64 = np.array([np.datetime64(t.replace(tzinfo=None)) for t in times])

coef = utide.solve(t64, sig, lat=47.6, constit=names,
                   method="ols", conf_int="none", trend=False, verbose=False)
uc = [{"name": n, "amp": a, "phase": g}
      for n, a, g in zip(coef["name"], coef["A"], coef["g"])]
rec = np.array([predict(uc, t) for t in times])             # reconstruct via utide coefs

skill = 1 - np.sum((sig - rec)**2) / np.sum((sig - sig.mean())**2)
rms = np.sqrt(np.mean((sig - rec)**2))
print(f"convention round-trip over 1 yr: skill={skill:.5f}  rms={rms:.4f} m  "
      f"(signal std {sig.std():.3f} m)")

inp = {c["name"]: (c["amp"], c["phase"]) for c in cons}
print("\nconst   inA    utA     inG     utG    dG(deg)")
for n, a, g in zip(coef["name"], coef["A"], coef["g"]):
    ia, ig = inp[n]
    dg = ((g - ig + 180) % 360) - 180
    print(f"{n:4s}  {ia:.3f}  {a:.3f}   {ig:6.1f}  {g:6.1f}   {dg:+5.1f}")
