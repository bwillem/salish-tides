#!/usr/bin/env python3
"""Harmonic tidal predictor — the astronomical engine that turns a set of
constituents (amplitude H, Greenwich phase g, per constituent) into a value at
any time t. Validated against NOAA here, then ported to Swift for on-device
current prediction (same math, applied to U and V components).

Convention: equilibrium argument V(t) is built from the mean longitudes at t
via Doodson coefficients on (tau, s, h, p, N, pp); nodal corrections f, u from
standard approximate formulas in N. value(t) = Σ f·H·cos(V + u − g).
"""
import math
from datetime import datetime, timezone

def _cosd(x): return math.cos(math.radians(x))
def _sind(x): return math.sin(math.radians(x))

def julian_day(dt):
    # dt: aware UTC
    y, m = dt.year, dt.month
    d = dt.day + (dt.hour + dt.minute/60 + dt.second/3600)/24
    if m <= 2:
        y -= 1; m += 12
    a = y // 100
    b = 2 - a + a//4
    return int(365.25*(y+4716)) + int(30.6001*(m+1)) + d + b - 1524.5

def astro(dt):
    """Mean longitudes (deg) + lunar time tau at UTC datetime dt."""
    T = (julian_day(dt) - 2451545.0) / 36525.0
    s  = 218.3164477 + 481267.88123421*T   # moon mean longitude
    h  = 280.4664490 + 36000.7698231*T     # sun mean longitude
    p  = 83.3532430  + 4069.0137110*T      # lunar perigee
    N  = 125.0445479 - 1934.1362891*T      # ascending node
    pp = 282.9373348 + 1.7195366*T         # solar perigee
    ut = dt.hour + dt.minute/60 + dt.second/3600
    tau = 15.0*ut - s + h                   # mean lunar time (deg)
    return dict(tau=tau % 360, s=s % 360, h=h % 360, p=p % 360, N=N % 360, pp=pp % 360)

# Doodson coefficients on (tau, s, h, p, N, pp) + phase offset in quarter-circles (×90°)
CONSTITUENTS = {
    'M2': dict(dood=(2, 0, 0, 0, 0, 0),  off=0),
    'S2': dict(dood=(2, 2,-2, 0, 0, 0),  off=0),
    'N2': dict(dood=(2,-1, 0, 1, 0, 0),  off=0),
    'K2': dict(dood=(2, 2, 0, 0, 0, 0),  off=0),
    'K1': dict(dood=(1, 1, 0, 0, 0, 0),  off=+1),
    'O1': dict(dood=(1,-1, 0, 0, 0, 0),  off=-1),
    'P1': dict(dood=(1, 1,-2, 0, 0, 0),  off=-1),
    'Q1': dict(dood=(1,-2, 0, 1, 0, 0),  off=-1),
}

def node_factors(name, N):
    """Approximate Schureman nodal amplitude f and phase u (deg) from N (deg)."""
    if name in ('M2', 'N2'):
        return 1.0004 - 0.0373*_cosd(N) + 0.0002*_cosd(2*N), -2.14*_sind(N)
    if name == 'K2':
        return 1.0241 + 0.2863*_cosd(N) + 0.0083*_cosd(2*N), -17.74*_sind(N) + 0.68*_sind(2*N)
    if name == 'K1':
        return 1.0060 + 0.1150*_cosd(N) - 0.0088*_cosd(2*N), -8.86*_sind(N) + 0.68*_sind(2*N)
    if name in ('O1', 'Q1'):
        return 1.0089 + 0.1871*_cosd(N) - 0.0147*_cosd(2*N), 10.80*_sind(N) - 1.34*_sind(2*N)
    return 1.0, 0.0   # S2, P1 (solar) — no nodal modulation

def equilibrium(name, a):
    c = CONSTITUENTS[name]
    d = c['dood']
    V = (d[0]*a['tau'] + d[1]*a['s'] + d[2]*a['h']
         + d[3]*a['p'] + d[4]*a['N'] + d[5]*a['pp'] + c['off']*90.0)
    return V

def predict(constituents, dt):
    """constituents: list of {name, amp (H), phase (g, deg Greenwich)}. Returns value."""
    a = astro(dt)
    total = 0.0
    for con in constituents:
        name = con['name']
        if name not in CONSTITUENTS:
            continue
        f, u = node_factors(name, a['N'])
        V = equilibrium(name, a)
        total += f * con['amp'] * _cosd(V + u - con['phase'])
    return total


if __name__ == '__main__':
    import json
    ref = json.load(open('dev/model/noaa_seattle_ref.json'))
    cons = [c for c in ref['constituents'] if c['name'] in CONSTITUENTS]
    print(f"predicting Seattle with {len(cons)} constituents: {[c['name'] for c in cons]}")
    obs, pred = [], []
    for p in ref['predictions']:
        dt = datetime.strptime(p['t'], '%Y-%m-%d %H:%M').replace(tzinfo=timezone.utc)
        obs.append(p['v'])
        pred.append(predict(cons, dt))
    import statistics
    n = len(obs)
    mo = statistics.mean(obs)
    # correlation + RMS (NOAA uses all 34 constituents; we use 8, so expect some residual)
    cov = sum((o-mo)*(p-statistics.mean(pred)) for o,p in zip(obs,pred))
    so = math.sqrt(sum((o-mo)**2 for o in obs)); sp = math.sqrt(sum((p-statistics.mean(pred))**2 for p in pred))
    corr = cov/(so*sp)
    rms = math.sqrt(sum((o-p)**2 for o,p in zip(obs,pred))/n)
    bias = statistics.mean(p-o for o,p in zip(obs,pred))
    print(f"vs NOAA (full 34-constituent) prediction over {n} hourly steps:")
    print(f"  correlation = {corr:.4f}   RMS = {rms:.3f} m   bias = {bias:+.3f} m   (signal range ~{max(obs)-min(obs):.2f} m)")
    print("  first 6h  obs vs pred:")
    for i in range(6):
        print(f"    {ref['predictions'][i]['t']}  obs={obs[i]:+.3f}  pred={pred[i]:+.3f}")
