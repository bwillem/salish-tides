#!/usr/bin/env python3
"""Extract current vectors from the Salish Sea Atlas using PyMuPDF (fitz).

Port of the original working Vol 1 extractor, generalized per volume. Arrows are
black drawing paths with exactly 7 line-segment items; position is the path
centroid; georeferencing is a least-squares fit over all gridline minute labels
with monotonicity-based degree assignment. Writes one map_<chart>_<region>.json
per page (array of {lat,lon,speed_ms,direction_deg}).
"""
import fitz, math, json, re, os, sys
import numpy as np

PDF_DIR = "/Users/bryan/salish-tides/dev/pdfs"

# Slack dots are pure visual fill; keep ~1 per cell of this size (~2 km).
SLACK_GRID_DEG = 0.018

VOLUMES = {
    1: {"pdf": "Salish Sea Tidal Current Atlas Volume 1 Version 1.01.pdf",
        "regions": "ABCDEFGH", "maps": 43, "regionA_start": 19,
        "bounds": (47.5, 50.0, -124.6, -122.0)},
    2: {"pdf": "Salish Sea Tidal Current Atlas Volume 2 Version 1.01.pdf",
        "regions": "ABCDEF", "maps": 64, "regionA_start": 19,
        "bounds": (46.8, 48.5, -123.95, -122.0)},
    3: {"pdf": "Salish Sea Tidal Current Atlas Volume 3 Version 1.0.pdf",
        "regions": "ABCDEFGH", "maps": 43, "regionA_start": 19,
        "bounds": (48.8, 51.3, -126.6, -123.5)},
    4: {"pdf": "Salish Sea Tidal Current Atlas Volume 4 Version 1.0.pdf",
        "regions": "ABCDEFGH", "maps": 69, "regionA_start": 19,
        "bounds": (49.5, 52.6, -129.6, -124.7)},
}


def text_items(page):
    items = []
    for b in page.get_text('dict')['blocks']:
        if 'lines' not in b:
            continue
        for line in b['lines']:
            for span in line['spans']:
                t = span['text'].strip()
                if t:
                    bb = span['bbox']
                    items.append({'text': t, 'x': (bb[0]+bb[2])/2, 'y': (bb[1]+bb[3])/2, 'bbox': bb})
    return items


def build_georef(page):
    ti = text_items(page)
    W, H = page.rect.width, page.rect.height
    # Degree labels carry both a value and a position. The position is the
    # meridian/parallel; minute ticks on either side belong to different whole
    # degrees. (Vol 4 Region G's "51°N" sits ABOVE its ticks, so they are
    # 50°55'… not 51°55' — assigning by value alone puts G/H 1° too far north.)
    lon_deg = lat_deg = None
    lon_deg_x = lat_deg_y = None
    for t in ti:
        m = re.match(r'(\d+)°W', t['text'])
        if m:
            lon_deg = int(m.group(1))
            lon_deg_x = t['x']
        m = re.match(r'(\d+)°N', t['text'])
        if m:
            lat_deg = int(m.group(1))
            lat_deg_y = t['y']
    if lon_deg is None or lat_deg is None:
        return None

    # Latitude labels hug the left edge; longitude labels sit on the bottom
    # border. A tight bottom threshold (proven to give ~1.4% on-land for the
    # 747-tall portrait pages) avoids spurious minute-like text in the map.
    # Landscape pages (Vol 4 Region F, 612 tall) put the labels relatively
    # higher, so use a lower fraction there.
    bottom_frac = 0.85 if W > H else 0.90
    bottom_y = H * bottom_frac
    left_x = W * 0.14
    lon_labels, lat_labels = [], []
    for t in ti:
        m = re.match(r"(\d+\.?\d*)'", t['text'])
        if not m:
            continue
        minutes = float(m.group(1))
        if minutes >= 60:
            continue
        is_bottom = t['bbox'][3] > bottom_y
        is_left = t['bbox'][0] < left_x
        if is_bottom and is_left:
            # Bottom-left corner label satisfies both edges (it's the corner
            # latitude OR longitude tick) — ambiguous, and assigning it to the
            # wrong axis corrupts that axis's fit. Skip it; the remaining ticks
            # fit fine and extrapolate over the dropped one.
            continue
        if is_bottom:                      # bottom edge → longitude
            lon_labels.append((t['x'], minutes))
        elif is_left:                      # left edge → latitude
            lat_labels.append((t['y'], minutes))

    # Anchor the first tick's whole degree by its side of the degree label
    # (handles charts whose ticks all sit on one side of the labelled line, e.g.
    # Vol 4 Region G where 51°N is north of every tick → they are 50°xx). Then
    # walk the rest by monotonicity (lon increases W→E; lat decreases N→S),
    # which absorbs degree crossings without trusting the label's exact x/y.
    lon_labels.sort(key=lambda p: p[0])
    lon_points = []
    for x, minutes in lon_labels:
        if not lon_points:
            deg = lon_deg if x <= lon_deg_x else lon_deg - 1
            val = -(deg + minutes/60)
        else:
            prev = lon_points[-1][1]
            cands = [-(d + minutes/60) for d in (lon_deg-2, lon_deg-1, lon_deg, lon_deg+1)]
            valid = [c for c in cands if c > prev]
            val = min(valid) if valid else -(lon_deg + minutes/60)
        lon_points.append((x, val))

    lat_labels.sort(key=lambda p: p[0])
    lat_points = []
    for y, minutes in lat_labels:
        if not lat_points:
            deg = lat_deg if y <= lat_deg_y else lat_deg - 1
            val = deg + minutes/60
        else:
            prev = lat_points[-1][1]
            cands = [d + minutes/60 for d in (lat_deg-2, lat_deg-1, lat_deg, lat_deg+1)]
            valid = [c for c in cands if c < prev]
            val = max(valid) if valid else lat_deg + minutes/60
        lat_points.append((y, val))

    if len(lon_points) < 2 or len(lat_points) < 2:
        return None
    lon_fit = np.polyfit([p[0] for p in lon_points], [p[1] for p in lon_points], 1)
    lat_fit = np.polyfit([p[0] for p in lat_points], [p[1] for p in lat_points], 1)
    return {'lon_fit': lon_fit, 'lat_fit': lat_fit}


def find_inset_rects(draws):
    insets = []
    for p in draws:
        rect = p['rect']
        if p.get('color') == (0.0, 0.0, 0.0) and not p.get('fill') and len(p['items']) == 1:
            if 80 < rect.width < 400 and 80 < rect.height < 400 and (p.get('width') or 0) > 0.5:
                insets.append(rect)
    uniq = []
    for r in insets:
        if not any(abs(r.x0-u.x0) < 5 and abs(r.y0-u.y0) < 5 for u in uniq):
            uniq.append(r)
    return uniq


def extract_slack_marks(draws, insets, W, H):
    """Tiny single-quad marks the atlas draws where current is below the
    minimum-arrow threshold (slack/weak). They carry position only (no
    direction). Capturing them — as zero-speed points — replicates the atlas:
    a dot at slack, an arrow at flow. Without them, weak-current cells (which
    shift with the tidal phase) read as missing data."""
    marks = []
    for p in draws:
        if p.get('color') != (0.0, 0.0, 0.0) or len(p['items']) != 1:
            continue
        if p['items'][0][0] != 'qu':
            continue
        r = p['rect']
        if r.width >= 5 or r.height >= 5:
            continue
        cx, cy = (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2
        if not (W * 0.13 < cx < W * 0.93 and H * 0.08 < cy < H * 0.93):
            continue
        if any(rr.x0 <= cx <= rr.x1 and rr.y0 <= cy <= rr.y1 for rr in insets):
            continue
        marks.append((cx, cy))
    return marks


def extract_arrows(draws, insets):
    arrows = []
    for p in draws:
        if p.get('color') != (0.0, 0.0, 0.0) or len(p['items']) != 7:
            continue
        items = p['items']
        if not all(it[0] == 'l' and hasattr(it[1], 'x') for it in items):
            continue
        pts = [it[1] for it in items]
        cx = sum(q.x for q in pts)/len(pts)
        cy = sum(q.y for q in pts)/len(pts)
        if any(r.x0 <= cx <= r.x1 and r.y0 <= cy <= r.y1 for r in insets):
            continue
        tip = items[3][1]
        bs = items[0][1]
        be = items[6][2] if hasattr(items[6][2], 'x') else items[6][1]
        bx, by = (bs.x+be.x)/2, (bs.y+be.y)/2
        dx, dy = tip.x - bx, -(tip.y - by)
        length = math.hypot(dx, dy)
        if length < 1:
            continue
        compass = (90 - math.degrees(math.atan2(dy, dx))) % 360
        # Store the shaft MIDPOINT (geometric centre of the arrow). The polygon
        # centroid is biased toward the wide arrowhead, so the stored point lands
        # near the tip and a symmetric ±half-length render leaves the tail
        # sticking out. The atlas centres arrows on their sample points (base
        # anchoring measured worse against the water mask), so the midpoint is
        # both the true centre for rendering and the right velocity-field sample.
        mx, my = (bx + tip.x) / 2, (by + tip.y) / 2
        arrows.append({'cx': mx, 'cy': my, 'length_px': length, 'direction_deg': compass})
    return arrows


def find_scale(page, arrows, insets):
    ti = text_items(page)
    scales = []
    for t in ti:
        m = re.match(r'([\d.]+)\s*m/s', t['text'])
        if m and not any(r.x0 <= t['x'] <= r.x1 and r.y0 <= t['y'] <= r.y1 for r in insets):
            scales.append({'v': float(m.group(1)), 'x': t['x'], 'y': t['y']})
    if not scales:
        return None
    scales.sort(key=lambda s: s['y'])
    main = scales[0]
    # The legend reference arrow is a HORIZONTAL (~90/270deg), full-length arrow
    # beside the label. Match it specifically -- not merely the nearest arrow:
    # current-data arrows are often drawn closer to the label and are short and
    # diagonal, so "nearest" gives a wildly wrong scale (Vol1 region E maps 3+
    # picked a ~7px data arrow -> 5-6x too fast, up to 14kn). The legend arrow is
    # 90-91deg / 38-40px across all four volumes, so a tight +/-15deg band keeps
    # a long, near-horizontal data arrow from ever out-matching it.
    best, bd = None, 1e9
    for a in arrows:
        d = math.hypot(a['cx']-main['x'], a['cy']-main['y'])
        horizontal = min(abs(a['direction_deg']-90), abs(a['direction_deg']-270)) < 15
        if d < 110 and horizontal and a['length_px'] > 20 and d < bd:
            bd, best = d, a
    if best:
        return main['v'] / best['length_px']
    return main['v'] / 39.0   # legend arrow is a fixed ~39px graphic


def process(doc, page_idx, bounds, fb_geo, fb_scale, max_speed):
    page = doc[page_idx]
    geo = build_georef(page) or fb_geo
    if geo is None:
        return None, fb_geo, fb_scale
    draws = page.get_drawings()
    insets = find_inset_rects(draws)
    arrows = extract_arrows(draws, insets)
    if not arrows:
        return [], geo, fb_scale
    scale = find_scale(page, arrows, insets) or fb_scale or (1.0/39.0)
    lonf, latf = geo['lon_fit'], geo['lat_fit']
    la0, la1, lo0, lo1 = bounds
    out = []
    for a in arrows:
        lon = lonf[0]*a['cx'] + lonf[1]
        lat = latf[0]*a['cy'] + latf[1]
        spd = a['length_px']*scale
        # max_speed is a sanity clip against extraction errors, set per volume:
        # it must clear the real maxima (Seymour/Nakwakto ~16kn=8.2m/s in the
        # northern vols) while still rejecting gross (4-6x) scale blowups.
        if lat < la0 or lat > la1 or lon < lo0 or lon > lo1 or spd > max_speed:
            continue
        out.append({'lat': round(lat, 5), 'lon': round(lon, 5),
                    'speed_ms': round(spd, 3), 'direction_deg': round(a['direction_deg'], 1)})
    # Slack/weak grid points → zero-speed dots (no direction), so weak-current
    # areas show as the atlas draws them rather than as missing data. They're
    # pure visual fill, so subsample to a coarse grid (~1.3 km) to keep the data
    # small; one dot per cell still reads as continuous coverage.
    W, H = page.rect.width, page.rect.height
    slack_seen = set()
    for cx, cy in extract_slack_marks(draws, insets, W, H):
        lon = lonf[0]*cx + lonf[1]
        lat = latf[0]*cy + latf[1]
        if lat < la0 or lat > la1 or lon < lo0 or lon > lo1:
            continue
        key = (round(lat / SLACK_GRID_DEG), round(lon / SLACK_GRID_DEG))
        if key in slack_seen:
            continue
        slack_seen.add(key)
        out.append({'lat': round(lat, 5), 'lon': round(lon, 5),
                    'speed_ms': 0.0, 'direction_deg': 0.0})
    return out, geo, scale


# Per-volume speed sanity clip (m/s). Southern vols (1/2, Gulf Islands / Puget
# Sound) top out near ~4 m/s, so a tight 8.0 catches errors; the northern vols
# (3/4) contain Seymour Narrows / Nakwakto Rapids (~16kn = ~8.2 m/s), so allow
# 9.0 m/s (~17.5kn) to clear the real maxima while still rejecting 4-6x blowups.
MAX_SPEED_MS = {1: 8.0, 2: 8.0, 3: 9.0, 4: 9.0}


def main():
    vol = int(sys.argv[1])
    outdir = sys.argv[2]
    cfg = VOLUMES[vol]
    max_speed = MAX_SPEED_MS.get(vol, 8.0)
    os.makedirs(outdir, exist_ok=True)
    doc = fitz.open(os.path.join(PDF_DIR, cfg['pdf']))
    regions = cfg['regions']
    maps = cfg['maps']
    a_start = cfg['regionA_start'] or 19
    total = 0
    for ri, region in enumerate(regions):
        start = a_start + ri*maps
        fb_geo = fb_scale = None
        for i in range(maps):
            idx = start + i
            chart = i + 1
            vecs, fb_geo, fb_scale = process(doc, idx, cfg['bounds'], fb_geo, fb_scale, max_speed)
            if vecs is None:
                vecs = []
            with open(os.path.join(outdir, f"map_{chart}_{region}.json"), 'w') as f:
                json.dump(vecs, f, separators=(',', ':'))
            total += len(vecs)
        print(f"  region {region}: done")
    print(f"Vol {vol}: {total} vectors -> {outdir}")


if __name__ == '__main__':
    main()
