"""Writes the sign textures as DDS with a full mip chain, compressed to BC7.

The mip chain is written uncompressed (32-bit BGRA), then texconv (Microsoft's DirectXTex,
TEXCONV) compresses it to BC7 in place, keeping the levels. Without texconv the textures stay
uncompressed: the game reads those too, but its mod validation warns ("please use BC1/DXT1 for
opaque textures"). BC1 is not an option: it stepped the diagonal edges and haloed the thin
outlines, visibly in game; BC7 looked the same as uncompressed (user, 2026-10-22).

Image rows are written top first, as an ordinary image: the top of the file is the top of the
sign. (The exporter flips Blender's v, which has v = 0 at the bottom.)

Faces: the user's artwork (SOURCE, 3840 px TGAs with alpha) when it is there, otherwise the
generated placeholders below. Artwork keeps its whole square image (not cropped: the plates follow
the artwork's own outline and take their UVs straight from image coordinates, see
tools/trace_sign_outlines.py; cropping and stretching to the square misaligned it, 2026-10-18),
scaled to FACE_SIZE with premultiplied alpha (so the transparent surroundings don't darken the
edges), and its transparent pixels are filled with the nearest edge colour (the material is
opaque; this keeps the plate's edge from sampling into the background).

FACE_SIZE 256: at the closest gameplay zoom the yield triangle covers about 55 px of a 1080p
screen (about 110 px at 4K), so 256 stays sharp with room to spare; mipmaps cover the distance
(2026-10-18).

Run: .venv/Scripts/python tools/make_sign_textures.py   (needs Pillow and NumPy for the artwork;
writes into mod/content/textures/models/imsvale_signs/)
"""
import glob
import os
import struct
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "mod", "content", "textures", "models", "imsvale_signs")
# texconv.exe from https://github.com/microsoft/DirectXTex/releases, kept in the shared
# mods/tools (git-ignored there)
TEXCONV = os.path.join(os.path.dirname(ROOT), "tools", "texconv.exe")

SOURCE = r"D:\My Documents\Games\Transport Fever 3\Graphics\yield"
FACE_SIZE = 256
ARTWORK = {  # texture -> the user's file in SOURCE
    "yield_face.dds": "yield_intl.tga",         # international, with a white outer rim (2026-10-18)
    "yield_no_face.dds": "yield_no.tga",        # Norwegian: tighter corners
    "roundabout_face.dds": "roundabout.tga",
    "priority_face.dds": "priority_diamond.tga",
}

RED = (200, 16, 32)
WHITE = (250, 250, 250)
METAL = (150, 152, 155)
BLUE = (0, 82, 164)
YELLOW = (250, 196, 0)
DARK = (40, 40, 40)


def yield_face(n=512, ss=3):
    """The yield face: an apex-down triangle filling the square (the plate's UVs map its
    corners to (0,1), (1,1), (0.5,0)), red border, white inside. Outside the triangle: metal."""
    border = 0.13  # share of the triangle's inradius that is red
    # corners in image space, y down: top-left, top-right, bottom-middle
    A, B, C = (0.0, 0.0), (1.0, 0.0), (0.5, 1.0)

    def inside(p, a, b, c):
        def s(p1, p2, p3):
            return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])
        d1, d2, d3 = s(p, a, b), s(p, b, c), s(p, c, a)
        return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))

    cx, cy = (A[0] + B[0] + C[0]) / 3, (A[1] + B[1] + C[1]) / 3
    k = 1 - border * 1.9
    Ai, Bi, Ci = [(cx + (p[0] - cx) * k, cy + (p[1] - cy) * k) for p in (A, B, C)]
    px = []
    for y in range(n):
        for x in range(n):
            acc = [0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    p = ((x + (sx + .5) / ss) / n, (y + (sy + .5) / ss) / n)
                    col = METAL
                    if inside(p, A, B, C):
                        col = WHITE if inside(p, Ai, Bi, Ci) else RED
                    for i in range(3):
                        acc[i] += col[i]
            px.append(tuple(int(v / (ss * ss)) for v in acc) + (255,))
    return n, px


def supersample(n, ss, colour_at):
    """An n x n image from colour_at(u, v) -> (r, g, b), u right, v down, both 0..1."""
    px = []
    for y in range(n):
        for x in range(n):
            acc = [0, 0, 0]
            for sy in range(ss):
                for sx in range(ss):
                    col = colour_at((x + (sx + .5) / ss) / n, (y + (sy + .5) / ss) / n)
                    for i in range(3):
                        acc[i] += col[i]
            px.append(tuple(int(v / (ss * ss)) for v in acc) + (255,))
    return n, px


def roundabout_face(n=512, ss=3):
    """The roundabout sign: a blue disc with a thin white rim and three white arrows going
    anticlockwise (right-hand traffic) around the centre. The disc fills the square; the plate's
    UVs map the disc onto it, outside it: metal."""
    import math
    arrow_r, band = 0.255, 0.075          # arrow centre radius and half-thickness (disc radius 0.5)
    head_len, head_half = 0.24, 0.12      # arrowhead length (radians along the arc) and half-width
    def colour_at(u, v):
        x, y = u - 0.5, 0.5 - v           # y up
        r = math.hypot(x, y)
        if r > 0.5:
            return METAL
        if r > 0.47:
            return WHITE
        a = math.atan2(y, x) % (2 * math.pi)
        for k in range(3):
            start = math.radians(90 + 120 * k + 20)        # each arrow: 80 degrees of arc, then its head
            rel = (a - start) % (2 * math.pi)
            body = math.radians(80)
            if rel <= body and abs(r - arrow_r) <= band:
                return WHITE
            if body < rel <= body + head_len:
                t = (rel - body) / head_len                # 0 at the head's base, 1 at its tip
                if abs(r - arrow_r) <= head_half * (1 - t):
                    return WHITE
        return BLUE
    return supersample(n, ss, colour_at)


def priority_face(n=512, ss=3):
    """The priority road sign: a diamond (the square turned 45 degrees, its corners at the
    square's edge midpoints, where the plate's UVs put them) with a thin dark edge, a white
    border and a yellow centre. Outside the diamond: metal."""
    def colour_at(u, v):
        d = abs(u - 0.5) + abs(v - 0.5)                    # 0.5 on the diamond's edge
        if d > 0.5:
            return METAL
        if d > 0.488:
            return DARK
        if d > 0.37:
            return WHITE
        return YELLOW
    return supersample(n, ss, colour_at)


def square(im):
    """The artwork centred on a transparent square canvas (some artwork isn't square, e.g.
    yield_intl.tga 3908 x 3467), so one uniform scale holds in both directions."""
    from PIL import Image
    n = max(im.size)
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    canvas.paste(im, ((n - im.size[0]) // 2, (n - im.size[1]) // 2))
    return canvas


def from_artwork(path, n=FACE_SIZE):
    """The user's artwork as an n x n face (see the module docstring)."""
    import numpy as np
    from PIL import Image
    im = square(Image.open(path).convert("RGBA"))
    # Premultiplied resize.
    arr = np.asarray(im).astype(np.float64) / 255.0
    arr[:, :, :3] *= arr[:, :, 3:4]
    chans = [Image.fromarray(arr[:, :, i].astype(np.float32), mode="F").resize((n, n), Image.LANCZOS) for i in range(4)]
    out = np.stack([np.asarray(c) for c in chans], axis=2).clip(0, 1)
    alpha = out[:, :, 3:4]
    rgb = np.where(alpha > 1e-4, out[:, :, :3] / np.maximum(alpha, 1e-4), 0).clip(0, 1)
    # Fill the transparent pixels from their filled neighbours, ring by ring.
    filled = alpha[:, :, 0] > 0.5
    for _ in range(n):
        if filled.all():
            break
        acc = np.zeros_like(rgb)
        cnt = np.zeros(filled.shape)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                sf = np.roll(np.roll(filled, dy, 0), dx, 1)
                sc = np.roll(np.roll(rgb, dy, 0), dx, 1)
                acc += sc * sf[:, :, None]
                cnt += sf
        grow = (~filled) & (cnt > 0)
        rgb[grow] = acc[grow] / cnt[grow][:, None]
        filled = filled | grow
    # Opaque from here: the colours inside the shape plus the filled surroundings.
    px = (rgb * 255 + 0.5).astype(np.uint8)
    return n, [tuple(int(v) for v in px[y, x]) + (255,) for y in range(n) for x in range(n)]


def solid(n, col):
    return n, [col + (255,)] * (n * n)


def downsample(n, px):
    m = n // 2
    out = []
    for y in range(m):
        for x in range(m):
            q = [px[(2 * y + dy) * n + 2 * x + dx] for dy in (0, 1) for dx in (0, 1)]
            out.append(tuple(sum(c[i] for c in q) // 4 for i in range(4)))
    return m, out


def write_dds(path, n, px):
    levels = [(n, px)]
    while levels[-1][0] > 1:
        levels.append(downsample(*levels[-1]))
    DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH, DDSD_PITCH, DDSD_PIXELFORMAT, DDSD_MIPMAPCOUNT = 0x1, 0x2, 0x4, 0x8, 0x1000, 0x20000
    flags = DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PITCH | DDSD_PIXELFORMAT | DDSD_MIPMAPCOUNT
    DDPF_ALPHAPIXELS, DDPF_RGB = 0x1, 0x40
    pf = struct.pack("<II4sIIIII", 32, DDPF_RGB | DDPF_ALPHAPIXELS, b"\0\0\0\0", 32,
                     0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    DDSCAPS_COMPLEX, DDSCAPS_TEXTURE, DDSCAPS_MIPMAP = 0x8, 0x1000, 0x400000
    header = struct.pack("<IIIIIII", 124, flags, n, n, n * 4, 0, len(levels)) + b"\0" * 44 + pf + \
        struct.pack("<IIIII", DDSCAPS_COMPLEX | DDSCAPS_TEXTURE | DDSCAPS_MIPMAP, 0, 0, 0, 0)
    body = bytearray()
    for _, lpx in levels:
        for r, g, b, a in lpx:
            body += bytes((b, g, r, a))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"DDS " + header + body)
    print("wrote", path, n, "x", n, len(levels), "levels")


if __name__ == "__main__":
    placeholders = {"yield_face.dds": yield_face, "yield_no_face.dds": yield_face,
                    "roundabout_face.dds": roundabout_face, "priority_face.dds": priority_face}
    for tex, make in placeholders.items():
        art = os.path.join(SOURCE, ARTWORK[tex])
        if os.path.exists(art):
            print("artwork", art)
            write_dds(os.path.join(OUT, tex), *from_artwork(art))
        else:
            print("placeholder for", tex)
            write_dds(os.path.join(OUT, tex), *make())
    write_dds(os.path.join(OUT, "sign_metal.dds"), *solid(16, METAL))
    if os.path.exists(TEXCONV):
        # -bc x: BC7's slowest, best search; the levels written above are kept
        subprocess.run([TEXCONV, "-nologo", "-f", "BC7_UNORM", "-bc", "x", "-y", "-o", OUT]
                       + sorted(glob.glob(os.path.join(OUT, "*.dds"))), check=True, stdout=subprocess.DEVNULL)
        print("compressed to BC7")
    else:
        print("no texconv at", TEXCONV, "- left uncompressed")
