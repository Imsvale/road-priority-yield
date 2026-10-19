"""Writes junction icons (mod/content/gui/*.tga) from the user's sign artwork, for sign styles that
have no hand-made 64 px icon (2026-10-19).

The international icons are the user's own 64 px files (e.g. yield_64px.tga -> gui/yield.tga). For
the Norwegian yield icon there is only the full-size artwork (yield_no.tga), so it's made here the
way the user's 64 px yield icon is framed: the artwork cropped to its opaque outline, scaled to the
icon's full width with premultiplied alpha (so the transparent surroundings don't darken the
edges), centred vertically on a transparent 64 x 64 canvas. Written as RLE 32-bit TGA, top row
first, like the user's icons.

Run: .venv/Scripts/python tools/make_gui_icons.py
"""
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = r"D:\My Documents\Games\Transport Fever 3\Graphics\yield"
GUI = os.path.join(ROOT, "mod", "content", "gui")
SIZE = 64

ICONS = {  # icon file in GUI -> (artwork in SOURCE, size in px)
    "yield-no.tga": ("yield_no.tga", 64),
    # Tab icons for the tool's settings panel, the size of the game's gear (symbol_gear_28.tga),
    # so the three tabs match (2026-10-19).
    "tab-roundabout.tga": ("roundabout.tga", 28),
    "tab-priority.tga": ("priority_diamond.tga", 28),
}


def icon(path, n=SIZE):
    im = Image.open(path).convert("RGBA")
    im = im.crop(im.getchannel("A").getbbox())
    w, h = im.size
    scale = n / max(w, h)
    size = (max(1, round(w * scale)), max(1, round(h * scale)))
    small = im.convert("RGBa").resize(size, Image.LANCZOS).convert("RGBA")
    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    canvas.paste(small, ((n - size[0]) // 2, (n - size[1]) // 2))
    return canvas


if __name__ == "__main__":
    for out, (art, n) in ICONS.items():
        img = icon(os.path.join(SOURCE, art), n)
        img.save(os.path.join(GUI, out), compression="tga_rle", orientation=-1)
        print("wrote", out, "alpha bbox", img.getchannel("A").getbbox())
