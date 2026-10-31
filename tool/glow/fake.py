"""A still of GTVL's home screen, put together the way the app draws it: the
wallpaper, the bottom vignette, the dock's glass (the backdrop blurred,
saturated and tinted, with its light edge) and the apps' tiles, the one in
focus lifted. Values are blended as the app blends them, in screen colour
space (sRGB-encoded). Sizes are dp, at a given number of pixels per dp.

  python3 fake.py frame.png tiles_dir selected out.png
tiles_dir holds tile0.png, tile1.png, ... (the apps' tiles, any size).
"""

import sys

import numpy as np
from PIL import Image

# The layout as on the TV it was measured from: 960 x 540 dp, wide tiles at
# size m (eight across), spacing 200 % (26 dp gaps), dock height 150 %.
SCREEN = (960.0, 540.0)
PAD = 38.0
TILE_W = (960 - 2 * PAD - 7 * 13) / 8
TILE_H = TILE_W * 9 / 16
GAP = 26.0
ROOM = 1.5
RADIUS = 10.0
LIFT = 1.12
DOCK_H = TILE_H * (1 + 0.36 * ROOM)
DOCK_TOP = SCREEN[1] - DOCK_H - SCREEN[1] * 0.07
TILE_TOP = DOCK_TOP + (DOCK_H - TILE_H) / 2

# The glass, from the app's defaults.
BLUR = 8.0
TINT = np.array([0x5A, 0x4A, 0x2E]) / 255.0
TINT_ALPHA = 0.08
VIBRANCY = 1.35
LINE_ALPHA = 0.12


def tile_rect(i, lifted=False):
    """Tile i's rectangle (left, top, width, height) in dp."""
    x = PAD + i * (TILE_W + GAP)
    if not lifted:
        return x, TILE_TOP, TILE_W, TILE_H
    w, h = TILE_W * LIFT, TILE_H * LIFT
    return x + (TILE_W - w) / 2, TILE_TOP + (TILE_H - h) / 2, w, h


def gaussian(image, sigma):
    """Separable Gaussian blur of an H x W x C image, edges clamped."""
    r = int(3 * sigma + 0.5)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2)
    k /= k.sum()
    out = image
    for axis in (0, 1):
        pad = [(0, 0)] * out.ndim
        pad[axis] = (r, r)
        p = np.pad(out, pad, mode="edge")
        acc = np.zeros_like(out)
        for i, w in enumerate(k):
            acc += w * np.take(p, range(i, i + out.shape[axis]), axis=axis)
        out = acc
    return out


def saturate(image, amount):
    luma = image @ np.array([0.2126, 0.7152, 0.0722])
    return np.clip(luma[..., None] + (image - luma[..., None]) * amount, 0, 1)


def rounded_mask(w, h, r):
    """Coverage (0..1) of a w x h pixel rounded rectangle of corner radius r."""
    y, x = np.mgrid[0:h, 0:w] + 0.5
    dx = np.maximum(np.maximum(r - x, x - (w - r)), 0)
    dy = np.maximum(np.maximum(r - y, y - (h - r)), 0)
    d = np.sqrt(dx * dx + dy * dy) - r
    inside = (dx > 0) & (dy > 0)
    return np.where(inside, np.clip(0.5 - d, 0, 1), 1.0)


def compose(frame, tiles, selected, ppd):
    """The home screen as an H x W x 3 float image, without any glow."""
    W, H = round(SCREEN[0] * ppd), round(SCREEN[1] * ppd)
    bg = np.asarray(frame.convert("RGB").resize((W, H), Image.LANCZOS), dtype=float) / 255.0
    # The vignette: black rising to 25 % from halfway down.
    t = np.clip((np.arange(H) + 0.5) / H * 2 - 1, 0, 1)
    bg = bg * (1 - 0x40 / 255.0 * t)[:, None, None]
    out = bg.copy()
    # The dock's glass.
    y0, y1 = round(DOCK_TOP * ppd), round((DOCK_TOP + DOCK_H) * ppd)
    glass = saturate(gaussian(bg, BLUR * ppd)[y0:y1], VIBRANCY)
    glass = glass * (1 - TINT_ALPHA) + TINT * TINT_ALPHA
    h = y1 - y0
    # Its light: a soft glow along the top, a top edge brightest a third of
    # the way across, and a fainter bottom edge.
    glow = np.clip(1 - (np.arange(h) + 0.5) / (h * 0.45), 0, 1) * 0.07
    glass = glass * (1 - glow[:, None, None]) + glow[:, None, None]
    line = max(1, round(1.0 * ppd))
    xs = (np.arange(W) + 0.5) / W
    top = np.interp(xs, [0, 0.32, 0.68, 1], [0.8, 2.6, 1.6, 0.8]) * LINE_ALPHA
    glass[:line] = glass[:line] * (1 - top[None, :, None]) + top[None, :, None]
    glass[-line:] = glass[-line:] * (1 - LINE_ALPHA * 0.6) + LINE_ALPHA * 0.6
    out[y0:y1] = glass
    # The tiles, rounded, the selected one lifted.
    for i, tile in enumerate(tiles):
        x, y, w, h = tile_rect(i, lifted=i == selected)
        px, py, pw, ph = round(x * ppd), round(y * ppd), round(w * ppd), round(h * ppd)
        face = np.asarray(tile.convert("RGB").resize((pw, ph), Image.LANCZOS), dtype=float) / 255.0
        r = RADIUS * (LIFT if i == selected else 1) * ppd
        a = rounded_mask(pw, ph, r)[..., None]
        out[py:py + ph, px:px + pw] = out[py:py + ph, px:px + pw] * (1 - a) + face * a
    return out


def save(image, path):
    Image.fromarray((np.clip(image, 0, 1) * 255 + 0.5).astype(np.uint8)).save(path)


if __name__ == "__main__":
    frame, tiles_dir, selected, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    tiles = [Image.open(f"{tiles_dir}/tile{i}.png") for i in range(6)]
    save(compose(Image.open(frame), tiles, selected, 2.0), out)
