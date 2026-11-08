#!/usr/bin/env python3
"""Builds JS8Call/Resources/WorldMap.bin, the offline base map for the
Stations Heard map, from Natural Earth 1:50m GeoJSON (public domain).

Download these from github.com/nvkelso/natural-earth-vector/tree/master/geojson
into one folder, then run:  python3 -I build_map_data.py <folder> <output.bin>

  ne_50m_land, ne_50m_lakes, ne_50m_admin_0_boundary_lines_land,
  ne_50m_admin_1_states_provinces_lines

Format (little endian): "FFMP", u8 version, u8 layer count, then per layer
u8 kind (0 land, 1 lakes, 2 country borders, 3 state borders), u32 ring
count, and per ring u32 point count then int16 (lon, lat) pairs in
hundredths of a degree. Land and lake rings are closed polygons.
"""
import json, os, struct, sys

TOLERANCE = 0.03     # degrees, Douglas-Peucker
SCALE = 100
MAX_LAKE_RANK = 4    # keep the larger lakes (Great Lakes, Winnipeg, Victoria, ...)


def simplify(pts, tol):
    if len(pts) < 3:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]; bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        norm = (dx * dx + dy * dy) ** 0.5
        best, idx = -1.0, -1
        for i in range(a + 1, b):
            px, py = pts[i]
            if norm == 0:
                d = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                d = abs(dy * px - dx * py + bx * ay - by * ax) / norm
            if d > best:
                best, idx = d, i
        if best > tol and idx > 0:
            keep[idx] = True
            stack += [(a, idx), (idx, b)]
    return [p for p, k in zip(pts, keep) if k]


def rings(geom, polygons):
    t, c = geom["type"], geom["coordinates"]
    if t == "Polygon":
        parts = c
    elif t == "MultiPolygon":
        parts = [r for poly in c for r in poly]
    elif t == "LineString":
        parts = [c]
    elif t == "MultiLineString":
        parts = c
    else:
        return []
    out = []
    for r in parts:
        r = simplify([(p[0], p[1]) for p in r], TOLERANCE)
        q = []
        for lon, lat in r:
            pt = (round(lon * SCALE), round(lat * SCALE))
            if not q or q[-1] != pt:
                q.append(pt)
        if len(q) >= (4 if polygons else 2):
            out.append(q)
    return out


def layer(folder, name, polygons, keep=lambda p: True):
    with open(os.path.join(folder, name + ".geojson")) as f:
        data = json.load(f)
    out = []
    for feat in data["features"]:
        if feat.get("geometry") and keep(feat.get("properties") or {}):
            out += rings(feat["geometry"], polygons)
    return out


def main():
    folder, dest = sys.argv[1], sys.argv[2]
    layers = [
        (0, layer(folder, "ne_50m_land", True)),
        (1, layer(folder, "ne_50m_lakes", True, lambda p: (p.get("scalerank") or 99) <= MAX_LAKE_RANK)),
        (2, layer(folder, "ne_50m_admin_0_boundary_lines_land", False)),
        (3, layer(folder, "ne_50m_admin_1_states_provinces_lines", False)),
    ]
    buf = bytearray(b"FFMP") + struct.pack("<BB", 1, len(layers))
    for kind, rs in layers:
        buf += struct.pack("<BI", kind, len(rs))
        for r in rs:
            buf += struct.pack("<I", len(r))
            for lon, lat in r:
                buf += struct.pack("<hh", lon, lat)
        print(f"kind {kind}: {len(rs)} rings, {sum(map(len, rs))} points")
    with open(dest, "wb") as f:
        f.write(buf)
    print(f"{dest}: {len(buf)} bytes")


main()
