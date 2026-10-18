"""Traces the outline of each sign artwork, for the plate geometry (2026-10-18).

The plates follow the artwork's own shape (rounded corners included), and each plate vertex gets
the texture coordinate of its own position in the artwork, at one uniform scale. Fitting the
rounded shape's bounding box onto a sharp-cornered plate misaligned either the sides or the
corners (user's overlay, yield.png).

For each artwork (all convex: triangle, disc, diamond):
- outline: the convex hull of the opaque pixels (alpha > 0.5), simplified to points no more than
  TOLERANCE (in image units) off the true outline;
- sharp: for polygons, the sharp-cornered shape the artwork was rounded from: the straight sides
  extended to meet (the rounded corner's fillet apex, the user's suggestion). Its side length
  gives the real-world size (yield 0.9 m sides, priority diamond 0.6 m sides); a disc's diameter
  is its width (0.6 m).

Writes assets/sign_outlines.json: { name: { "outline": [[u, v], ...], "sharp": [[u, v], ...] or
null, "metres_per_unit": s } } with u right and v down, both 0..1 across the whole artwork image
(the texture is the whole image, uncropped, padded to a square when it isn't one). The Blender build script (tools/blender_build_signs.py)
reads it.

Run: .venv/Scripts/python tools/trace_sign_outlines.py
"""
import json
import math
import os

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = r"D:\My Documents\Games\Transport Fever 3\Graphics\yield"
OUT = os.path.join(ROOT, "assets", "sign_outlines.json")
WORK = 1024          # trace at this resolution
TOLERANCE = 0.0015   # simplified outline stays within this of the hull (image units; ~1.3 mm on a 0.9 m sign)

SIGNS = {
    # name: (file, straight sides (0 for a disc), real-world size: sharp side length or diameter, metres)
    # The yield artwork includes a white outer rim; the 0.9 m sharp triangle is taken around it.
    "yield": ("yield_intl.tga", 3, 0.9),        # international (2026-10-18)
    "yield_no": ("yield_no.tga", 3, 0.9),       # Norwegian: tighter corners
    "roundabout": ("roundabout.tga", 0, 0.6),
    "priority": ("priority_diamond.tga", 4, 0.6),
}


def hull(points):
    """Convex hull (Andrew's monotone chain), counter-clockwise in (u, v) with v down."""
    pts = sorted(set(map(tuple, points)))
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def simplify(poly, tol):
    """Douglas-Peucker on a closed polygon."""
    def dp(pts):
        if len(pts) < 3:
            return pts
        a, b = np.array(pts[0]), np.array(pts[-1])
        ab = b - a
        L = np.hypot(*ab)
        best, idx = -1.0, 0
        for i in range(1, len(pts) - 1):
            p = np.array(pts[i])
            d = abs(ab[0] * (p - a)[1] - ab[1] * (p - a)[0]) / L if L > 0 else np.hypot(*(p - a))
            if d > best:
                best, idx = d, i
        if best <= tol:
            return [pts[0], pts[-1]]
        return dp(pts[:idx + 1])[:-1] + dp(pts[idx:])
    # Split at the two points furthest apart so both halves are open chains.
    arr = np.array(poly)
    i = int(np.argmax(arr[:, 0] + arr[:, 1]))
    j = int(np.argmin(arr[:, 0] + arr[:, 1]))
    if i > j:
        i, j = j, i
    first = dp(poly[i:j + 1])
    second = dp(poly[j:] + poly[:i + 1])
    return first[:-1] + second[:-1]


def sharp_polygon(outline, sides):
    """The straight sides (the longest edges of the simplified outline, one per side direction)
    extended to meet."""
    n = len(outline)
    edges = []
    for k in range(n):
        a, b = np.array(outline[k]), np.array(outline[(k + 1) % n])
        edges.append((float(np.hypot(*(b - a))), a, b))
    edges.sort(key=lambda e: -e[0])
    chosen = []

    def same_line(a, b, ca, cb):
        d = (b - a) / np.hypot(*(b - a))
        c = (cb - ca) / np.hypot(*(cb - ca))
        if abs(d[0] * c[1] - d[1] * c[0]) > 0.2:
            return False                       # different directions
        off = a - ca
        return abs(off[0] * c[1] - off[1] * c[0]) < 0.05   # parallel and on (nearly) the same line
    # Opposite sides of a diamond are parallel but different lines: only reject the same line.
    for L, a, b in edges:
        if not any(same_line(a, b, ca, cb) for _, ca, cb in chosen):
            chosen.append((L, a, b))
        if len(chosen) == sides:
            break
    # Order the lines by the angle of their midpoints around the centre, then intersect neighbours.
    centre = np.mean(np.array(outline), axis=0)
    chosen.sort(key=lambda e: math.atan2(*(((e[1] + e[2]) / 2 - centre)[::-1])))
    corners = []
    for k in range(sides):
        _, a1, b1 = chosen[k]
        _, a2, b2 = chosen[(k + 1) % sides]
        d1, d2 = b1 - a1, b2 - a2
        den = d1[0] * d2[1] - d1[1] * d2[0]
        t = ((a2 - a1)[0] * d2[1] - (a2 - a1)[1] * d2[0]) / den
        corners.append([float(x) for x in a1 + t * d1])
    return corners


def square(im):
    """The artwork centred on a transparent square canvas (some artwork isn't square, e.g.
    yield_intl.tga 3908 x 3467), so one uniform scale holds in both directions."""
    from PIL import Image
    n = max(im.size)
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    canvas.paste(im, ((n - im.size[0]) // 2, (n - im.size[1]) // 2))
    return canvas


def trace(path, sides, size):
    im = square(Image.open(path).convert("RGBA")).resize((WORK, WORK), Image.LANCZOS)
    a = np.asarray(im)[:, :, 3] > 127
    # Boundary pixels only (opaque with a transparent 4-neighbour), at pixel centres.
    pad = np.pad(a, 1)
    edge = a & ~(pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:])
    ys, xs = np.nonzero(edge)
    pts = [((x + 0.5) / WORK, (y + 0.5) / WORK) for x, y in zip(xs, ys)]
    outline = simplify(hull(pts), TOLERANCE)
    if sides:
        sharp = sharp_polygon(outline, sides)
        side = float(np.mean([np.hypot(*(np.array(sharp[k]) - np.array(sharp[(k + 1) % sides]))) for k in range(sides)]))
        metres = size / side
    else:
        sharp = None
        us = [p[0] for p in outline]
        metres = size / (max(us) - min(us))
    return {"outline": [[round(u, 6), round(v, 6)] for u, v in outline],
            "sharp": sharp and [[round(u, 6), round(v, 6)] for u, v in sharp],
            "metres_per_unit": metres}


if __name__ == "__main__":
    result = {}
    for name, (file, sides, size) in SIGNS.items():
        result[name] = trace(os.path.join(SOURCE, file), sides, size)
        r = result[name]
        print(name, len(r["outline"]), "outline points,", "sharp corners", r["sharp"], "metres/unit %.4f" % r["metres_per_unit"])
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    print("wrote", OUT)
