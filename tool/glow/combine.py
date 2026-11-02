"""Puts a reference together: the glass pass as the screen shows it, plus the
glow pass's light through look.py's film-like curve, added on top as the app
adds its glow.

  python3 combine.py glass.png glow.npy exposure out.png [crop: x y w h in dp]
"""

import sys

import numpy as np
from PIL import Image

import look


def combine(glass_png, glow_npy, exposure):
    glass = np.asarray(Image.open(glass_png).convert("RGB"), dtype=float) / 255.0
    glow = look.tone(np.load(glow_npy), exposure)
    if glow.shape[:2] != glass.shape[:2]:
        glow = np.asarray(
            Image.fromarray((glow * 255).astype(np.uint8)).resize((glass.shape[1], glass.shape[0]), Image.LANCZOS),
            dtype=float,
        ) / 255.0
    return np.clip(glass + glow, 0, 1)


if __name__ == "__main__":
    glass_png, glow_npy, exposure, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
    image = combine(glass_png, glow_npy, exposure)
    result = Image.fromarray((image * 255 + 0.5).astype(np.uint8))
    if len(sys.argv) > 5:
        x, y, w, h = map(float, sys.argv[5:9])
        ppd = result.width / 960
        result = result.crop((round(x * ppd), round(y * ppd), round((x + w) * ppd), round((y + h) * ppd)))
        result = result.resize((round(w * 2), round(h * 2)), Image.LANCZOS)
    result.save(out)
