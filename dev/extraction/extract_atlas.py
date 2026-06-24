#!/usr/bin/env python3
"""
Extract current vector data from Salish Sea Tidal Current Atlas PDFs.

Each arrow in the atlas PDFs is an 8-point closed polygon:
  - The two TAIL points are the closest pair (forming the shaft width at the tail end)
  - The HEAD TIP is the point farthest from the tail centroid
  - Each physical arrow appears twice (stroke + fill paths)

Usage:
  python3 extract_atlas.py --validate              # compare Vol 1 extraction vs existing JSON
  python3 extract_atlas.py --vol 2 [--output-dir /path]
  python3 extract_atlas.py --vol 2 --chart 1 --region A  # single chart
"""

import pdfplumber
import re
import math
import json
import argparse
import os
import sys

ATLAS_DIR = "/Users/bryan/salish-tides/ios-production-handoff/atlas-source"
DEFAULT_OUTPUT = "/Users/bryan/salish-tides/ios-production-handoff/data/maps"
CALIBRATION_PATH = os.path.join(os.path.dirname(__file__), "vol1_pts_per_ms.json")

VOLUMES = {
    1: {
        "pdf": "Salish Sea Tidal Current Atlas Volume 1 Version 1.01.pdf",
        "n_charts": 43,
        "regions": list("ABCDEFGH"),
        "header_top_max": 15,
    },
    2: {
        "pdf": "Salish Sea Tidal Current Atlas Volume 2 Version 1.01.pdf",
        "n_charts": 64,
        "regions": list("ABCDEF"),
        "header_top_max": 15,
    },
    3: {
        "pdf": "Salish Sea Tidal Current Atlas Volume 3 Version 1.0.pdf",
        "n_charts": 43,
        "regions": list("ABCDEFGH"),
        "header_top_max": 15,
    },
    4: {
        "pdf": "Salish Sea Tidal Current Atlas Volume 4 Version 1.0.pdf",
        "n_charts": 69,
        "regions": list("ABCDEFGH"),
        "header_top_max": 55,  # Vol 4 title is at y≈47.7, not y≈7.4
    },
}

# Global default (0.5 m/s scale charts); overridden per-chart by calibration table.
PTS_PER_MS = 46.4

# Minimum arrow shaft length to include (pts).  Filters zero-speed / noise.
MIN_SHAFT_PTS = 2.0

# Fallback pts_per_ms by scale when per-chart calibration is unavailable.
# Derived from Vol 1 medians across all charts with that scale.
_SCALE_FALLBACK = {
    0.25: 153.94,
    0.5:  77.05,
    1.0:  38.87,
    1.5:  25.91,
    2.0:  19.61,
    3.0:  19.61,
    4.0:  19.61,
}

# Per-chart calibration loaded lazily from vol1_pts_per_ms.json.
_calibration_cache = None

def _load_calibration():
    global _calibration_cache
    if _calibration_cache is None:
        if os.path.exists(CALIBRATION_PATH):
            with open(CALIBRATION_PATH) as f:
                _calibration_cache = json.load(f)
        else:
            _calibration_cache = {}
    return _calibration_cache

def get_pts_per_ms(chart, region, scale_ms):
    """Return calibrated pts_per_ms for a (chart, region), falling back to scale median."""
    cal = _load_calibration()
    key = f"{chart}_{region}"
    if key in cal:
        return cal[key]["pts_per_ms"]
    # Scale fallback: use nearest known scale
    closest = min(_SCALE_FALLBACK.keys(), key=lambda s: abs(s - scale_ms))
    return _SCALE_FALLBACK[closest]


def page_index(vol, chart, region):
    """Return 0-indexed page number for the given (vol, chart, region)."""
    cfg = VOLUMES[vol]
    r_offset = ord(region) - ord('A')
    return 18 + r_offset * cfg['n_charts'] + chart


def extract_geo_transform(words):
    """
    Build lat/lon ↔ PDF-top-coordinate linear transforms from degree/minute labels.

    Left-edge minute labels → latitude fixes.
    Bottom-edge minute labels → longitude fixes.
    Degree labels ("48°N", "122°W") tell us which degree the minutes belong to.

    Returns (y_to_lat, x_to_lon) or None on failure.
    """
    lat_deg = None
    lon_deg = None

    for w in words:
        t = w['text']
        m = re.match(r'^(\d+)°N$', t)
        if m:
            lat_deg = int(m.group(1))
        m = re.match(r'^(\d+)°W$', t)
        if m:
            lon_deg = int(m.group(1))

    if lat_deg is None or lon_deg is None:
        return None

    lat_points = []  # (top_y, lat_decimal)
    lon_points = []  # (x, lon_decimal)

    for w in words:
        t = w['text']
        m = re.match(r"^(\d+(?:\.\d+)?)'$", t)
        if not m:
            continue
        mins = float(m.group(1))
        if mins > 59.9:
            continue

        # Left-edge label (x < 90, not at very bottom) → latitude
        if w['x0'] < 90 and w['top'] < 700:
            lat_points.append((w['top'], lat_deg + mins / 60.0))

        # Bottom-edge label (near bottom, x inside map area) → longitude
        elif w['top'] > 695 and w['top'] < 740 and 90 < w['x0'] < 590:
            lon_points.append((w['x0'], -(lon_deg + mins / 60.0)))

    if len(lat_points) < 2 or len(lon_points) < 2:
        return None

    lat_points.sort(key=lambda p: p[0])
    y_n, lat_n = lat_points[0]   # northernmost (smallest top)
    y_s, lat_s = lat_points[-1]  # southernmost (largest top)
    if abs(y_s - y_n) < 50:
        return None
    dlat_dy = (lat_s - lat_n) / (y_s - y_n)  # negative (lat decreases going down)

    lon_points.sort(key=lambda p: p[0])
    x_w, lon_w = lon_points[0]   # westernmost (smallest x, most negative lon)
    x_e, lon_e = lon_points[-1]  # easternmost (largest x, least negative lon)
    if abs(x_e - x_w) < 50:
        return None
    dlon_dx = (lon_e - lon_w) / (x_e - x_w)  # positive

    def y_to_lat(y_top):
        return lat_n + (y_top - y_n) * dlat_dy

    def x_to_lon(x):
        return lon_w + (x - x_w) * dlon_dx

    return y_to_lat, x_to_lon


def extract_scale_bar(words):
    """
    Return (max_scale_ms, map_start_top) where map_start_top is the y-coordinate
    (in pdfplumber top units) below which the map area begins.

    Only considers scale-bar texts in the page header (top < 150) to avoid
    picking up inset-map labels that can appear anywhere on the page.
    """
    max_ms = None
    lowest_header_top = 0.0

    for w in words:
        t = w['text']
        m = re.match(r'^(\d+(?:\.\d+)?)m/s', t)
        if m and w['top'] < 150:  # header-only
            val = float(m.group(1))
            if max_ms is None or val > max_ms:
                max_ms = val
            if w['top'] > lowest_header_top:
                lowest_header_top = w['top']

    return max_ms, lowest_header_top + 10.0  # 10 pt buffer below scale bar text


def extract_arrow(curve_pts, page_height):
    """
    Given the 8 points of a closed arrow polygon, extract shaft geometry.

    Closed paths have pts[7] == pts[0]. Work with only the 7 unique points.

    Algorithm:
    1. Find the pair (A, B) with maximum pairwise distance — this spans the full shaft.
    2. Of A and B, the one with a CLOSER nearest neighbor is the TAIL endpoint
       (because the two tail points are very close ~0.5 pt, while the arrowhead tip
       has no twin; its nearest neighbor is a barb base ~3 pt away).
    3. The tail center = average of the tail endpoint and its twin.
    4. The head tip = the other endpoint of the max-distance pair.

    Returns (tail_x, tail_top, head_x, head_top, shaft_length) or None.
    """
    if len(curve_pts) != 8:
        return None

    # 7 unique points (exclude closure duplicate pts[7] == pts[0])
    pts = curve_pts[:7]

    # Step 1: find the max-distance pair
    max_d, max_i, max_j = 0, 0, 1
    for i in range(7):
        for j in range(i + 1, 7):
            d = math.sqrt((pts[i][0] - pts[j][0]) ** 2 + (pts[i][1] - pts[j][1]) ** 2)
            if d > max_d:
                max_d, max_i, max_j = d, i, j

    # Step 2: for each endpoint (max_i, max_j), find nearest neighbor among OTHER points
    def nearest_neighbor_dist(idx):
        best = float('inf')
        for k in range(7):
            if k == idx:
                continue
            d = math.sqrt((pts[k][0] - pts[idx][0]) ** 2 + (pts[k][1] - pts[idx][1]) ** 2)
            if d < best:
                best = d
                best_k = k
        return best, best_k

    nn_i, twin_i = nearest_neighbor_dist(max_i)
    nn_j, twin_j = nearest_neighbor_dist(max_j)

    # The endpoint with the closer nearest neighbor is the tail (its twin is ~0.5 pt away)
    if nn_i <= nn_j:
        tail_idx, twin_idx, head_idx = max_i, twin_i, max_j
    else:
        tail_idx, twin_idx, head_idx = max_j, twin_j, max_i

    tail_x = (pts[tail_idx][0] + pts[twin_idx][0]) / 2
    tail_y_pdf = (pts[tail_idx][1] + pts[twin_idx][1]) / 2
    tail_top = page_height - tail_y_pdf

    head_x = pts[head_idx][0]
    head_top = page_height - pts[head_idx][1]

    shaft_len = math.sqrt((head_x - tail_x) ** 2 + (head_top - tail_top) ** 2)

    return tail_x, tail_top, head_x, head_top, shaft_len


def extract_inset_exclusion_zones(page, map_start_top):
    """
    Return list of (x0, x1, top0, top1) rectangles that are inset map panels
    entirely inside the map area. We exclude arrows whose tail falls inside such
    a panel to avoid double-counting currents drawn in the inset at a different
    coordinate scale.

    We only exclude panels that are entirely below map_start_top (i.e., both top
    corners are in the map area). Panels that straddle the header/map boundary
    are the standard scale-bar panels whose arrows are already deduplicated.
    """
    page_h = page.height
    exclusions = []
    for r in page.rects:
        top = page_h - r['y1']
        bot = page_h - r['y0']
        w = r['width']
        h = r['height']
        fill = r.get('non_stroking_color')
        is_white = fill in [(1.0, 1.0, 1.0), (1, 1, 1)]
        # Small white rect entirely within the map area (not crossing the header boundary)
        if (is_white and w < 300 and h < 300 and w * h < 60000
                and top > map_start_top and bot > map_start_top):
            exclusions.append((r['x0'], r['x1'], top, bot))
    return exclusions


def extract_vectors_from_page(page, y_to_lat, x_to_lon, map_start_top,
                               pts_per_ms=PTS_PER_MS):
    """
    Extract current vectors from a page. Returns list of {lat, lon, speed_ms, direction_deg}.

    Algorithm:
    1. Collect all 8-pt closed curves in the map area (not in border columns)
    2. Extract shaft (tail→head) from each curve
    3. Deduplicate (each arrow appears twice in the PDF)
    4. Convert shaft geometry to lat/lon/speed/direction
    """
    page_h = page.height
    seen = set()
    vectors = []

    # Determine inset panels to exclude (small white rects in map area)
    exclusions = extract_inset_exclusion_zones(page, map_start_top)

    for curve in page.curves:
        pts = curve.get('pts', [])
        if len(pts) != 8:
            continue

        # Must be in map area (below scale bar)
        xs = [p[0] for p in pts]
        ys_top = [page_h - p[1] for p in pts]

        # Skip border columns
        if max(xs) > 590 or min(xs) < 90:
            continue

        # Must be in map area
        if not any(yt > map_start_top for yt in ys_top):
            continue

        result = extract_arrow(pts, page_h)
        if result is None:
            continue

        tail_x, tail_top, head_x, head_top, shaft_len = result

        if shaft_len < MIN_SHAFT_PTS:
            continue

        # Skip arrows whose tail falls inside an inset panel
        in_inset = any(x0 <= tail_x <= x1 and t0 <= tail_top <= t1
                       for x0, x1, t0, t1 in exclusions)
        if in_inset:
            continue

        # Deduplicate: round to 0.5 pt grid
        key = (round(tail_x * 2), round(tail_top * 2), round(head_x * 2), round(head_top * 2))
        if key in seen:
            continue
        seen.add(key)

        # Direction: from tail to head
        # dx > 0 = eastward; dy_top < 0 = northward (top decreases going north)
        dx = head_x - tail_x
        dy_top = head_top - tail_top   # negative when going north

        # Compass bearing: atan2(east, north)
        # north = -dy_top (since dy_top is negative going north)
        direction_deg = math.degrees(math.atan2(dx, -dy_top)) % 360

        # Speed from shaft length
        speed_ms = shaft_len / pts_per_ms

        # Position from tail (where the current originates)
        lat = y_to_lat(tail_top)
        lon = x_to_lon(tail_x)

        # Sanity check
        if not (40 < lat < 55 and -132 < lon < -118):
            continue

        vectors.append({
            "lat": round(lat, 5),
            "lon": round(lon, 5),
            "speed_ms": round(speed_ms, 4),
            "direction_deg": round(direction_deg, 1),
        })

    return vectors


def extract_chart_vectors(pdf, vol, chart, region, pts_per_ms=None):
    """Extract vectors for a single (chart, region) from an open PDF object."""
    cfg = VOLUMES[vol]
    idx = page_index(vol, chart, region)

    if idx >= len(pdf.pages):
        return None, f"Page index {idx} out of range ({len(pdf.pages)} pages)"

    page = pdf.pages[idx]
    words = page.extract_words()

    # Verify this is the right page
    top_max = cfg['header_top_max']
    header_words = [w['text'] for w in words if w['top'] < top_max]
    all_words_text = ' '.join(w['text'] for w in words[:20])
    if f"Map {chart}{region}" not in ' '.join(header_words) and \
       f"Map {chart}{region}" not in all_words_text:
        return None, f"Header mismatch for Vol{vol} chart {chart}{region}"

    transform = extract_geo_transform(words)
    if transform is None:
        return None, "Could not extract geographic transform"
    y_to_lat, x_to_lon = transform

    scale_ms, map_start_top = extract_scale_bar(words)
    if scale_ms is None:
        return None, "Could not find scale bar"

    # Use per-chart calibrated pts_per_ms (override only if explicitly passed)
    if pts_per_ms is None:
        pts_per_ms = get_pts_per_ms(chart, region, scale_ms)

    vectors = extract_vectors_from_page(page, y_to_lat, x_to_lon, map_start_top, pts_per_ms)
    return vectors, None


def run_validation(vol=1, sample_charts=None):
    """Validate extraction on Vol 1 against existing JSON files."""
    cfg = VOLUMES[vol]
    pdf_path = os.path.join(ATLAS_DIR, cfg['pdf'])
    data_dir = DEFAULT_OUTPUT

    if sample_charts is None:
        sample_charts = [(1, 'A'), (3, 'F'), (5, 'E'), (10, 'B'), (20, 'D'),
                         (41, 'F'), (43, 'H'), (42, 'F')]

    print(f"Validating Vol {vol} extraction against existing JSON...")
    print(f"{'Chart':8} {'n_ext':6} {'n_exp':6} {'max_ext':8} {'max_exp':8} {'ratio':6} {'avg_ext':8} {'avg_exp':8}")

    with pdfplumber.open(pdf_path) as pdf:
        for chart, region in sample_charts:
            json_path = os.path.join(data_dir, f"map_{chart}_{region}.json")
            vectors, err = extract_chart_vectors(pdf, vol, chart, region)

            if err:
                print(f"  {chart}{region}: ERROR - {err}")
                continue

            if not vectors:
                print(f"  {chart}{region}: 0 vectors extracted")
                continue

            ext_speeds = [v['speed_ms'] for v in vectors]
            ext_max = max(ext_speeds)
            ext_avg = sum(ext_speeds) / len(ext_speeds)

            if os.path.exists(json_path):
                with open(json_path) as f:
                    expected = json.load(f)
                exp_speeds = [v['speed_ms'] for v in expected]
                exp_max = max(exp_speeds)
                exp_avg = sum(exp_speeds) / len(exp_speeds)
                ratio = ext_max / exp_max if exp_max else 0
                print(f"  {chart:2d}{region}    {len(vectors):6d} {len(expected):6d}"
                      f"  {ext_max:8.3f} {exp_max:8.3f} {ratio:6.2f}  {ext_avg:8.3f} {exp_avg:8.3f}")
            else:
                print(f"  {chart:2d}{region}    {len(vectors):6d}   N/A"
                      f"  {ext_max:8.3f}    N/A         {ext_avg:8.3f}    N/A")


def extract_volume(vol, output_dir, skip_existing=False):
    """Extract all charts for a volume and save JSON files."""
    cfg = VOLUMES[vol]
    pdf_path = os.path.join(ATLAS_DIR, cfg['pdf'])
    n_total = cfg['n_charts'] * len(cfg['regions'])

    print(f"\nExtracting Vol {vol}: {cfg['n_charts']} charts × {len(cfg['regions'])} regions = {n_total} pages")
    print(f"  Output dir: {output_dir}")

    done = 0
    errors = []
    vectors = None

    with pdfplumber.open(pdf_path) as pdf:
        for region in cfg['regions']:
            for chart in range(1, cfg['n_charts'] + 1):
                out_path = os.path.join(output_dir, f"map_{chart}_{region}.json")

                if skip_existing and os.path.exists(out_path):
                    done += 1
                    continue

                vectors, err = extract_chart_vectors(pdf, vol, chart, region)

                if err:
                    errors.append((chart, region, err))
                elif not vectors:
                    errors.append((chart, region, "0 vectors extracted"))
                else:
                    with open(out_path, 'w') as f:
                        json.dump(vectors, f, separators=(',', ':'))

                done += 1
                if done % 100 == 0:
                    label = f"{chart}{region}"
                    n_v = len(vectors) if vectors else 0
                    print(f"  {done}/{n_total} [{label}] {n_v} vectors", flush=True)

            print(f"  Region {region} done", flush=True)

    print(f"\nDone: {done - len(errors)} ok, {len(errors)} errors")
    if errors:
        for c, r, e in errors[:20]:
            print(f"  {c}{r}: {e}")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vol', type=int, choices=[1, 2, 3, 4])
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--output-dir', default=DEFAULT_OUTPUT)
    parser.add_argument('--skip-existing', action='store_true')
    parser.add_argument('--chart', type=int)
    parser.add_argument('--region')
    parser.add_argument('--pts-per-ms', type=float, default=PTS_PER_MS)
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    if args.validate:
        run_validation(vol=args.vol or 1)
        return

    if args.chart and args.region and args.vol:
        cfg = VOLUMES[args.vol]
        pdf_path = os.path.join(ATLAS_DIR, cfg['pdf'])
        with pdfplumber.open(pdf_path) as pdf:
            vectors, err = extract_chart_vectors(pdf, args.vol, args.chart, args.region,
                                                  args.pts_per_ms)
        if err:
            print(f"Error: {err}", file=sys.stderr)
            sys.exit(1)
        print(f"Extracted {len(vectors)} vectors")
        if vectors:
            speeds = [v['speed_ms'] for v in vectors]
            print(f"Speed: min={min(speeds):.3f} max={max(speeds):.3f} avg={sum(speeds)/len(speeds):.3f} m/s")
            print(json.dumps(vectors[:3], indent=2))
        return

    if args.vol:
        out_dir = args.output_dir
        if out_dir == DEFAULT_OUTPUT and args.vol != 1:
            # Auto-create vol-specific subdirectory unless user overrides
            out_dir = os.path.join(
                os.path.dirname(DEFAULT_OUTPUT),
                f"maps_vol{args.vol}"
            )
        os.makedirs(out_dir, exist_ok=True)
        extract_volume(args.vol, out_dir, skip_existing=args.skip_existing)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
