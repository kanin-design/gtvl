"""One look lit brighter in steps: each step is the traced glow of a base look
times a, plus b times another look's (light adds), over the base's glass; put
together as the home screen, cropped to the dock's left half, labelled and
stacked on one sheet.

  python3 ladder.py base other sheet.png a:b ...
base and other name traced looks cached by fit.py (out/<name>-ref.npz) whose
parameters are looks/<name>.json.
"""

import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import guide
import slab

HERE = os.path.dirname(os.path.abspath(__file__))


def traced(name):
    """A look's parameters and its cached trace, as guide.simulate returns them."""
    P = {**guide.DEFAULTS, **json.load(open(os.path.join(HERE, "looks", f"{name}.json")))}
    z = np.load(os.path.join(HERE, "out", f"{name}-ref.npz"))
    g = z["grid"]
    grid = (float(g[0]), float(g[1]), int(g[2]), int(g[3]))
    return P, {"glass": (z["glass_band"], z["wall_full"]), "glow": (z["glow_band"], z["glow_full"])}, grid


def mixed(mix):
    """The glow of looks lit together, [(name, share), ...], over the first's glass."""
    looks = [(traced(name), share) for name, share in mix]
    (P, sim, grid), _ = looks[0]
    band = sum(share * s["glow"][0] for (_, s, _), share in looks)
    full = sum(share * s["glow"][1] for (_, s, _), share in looks)
    return P, {"glass": sim["glass"], "glow": (band, full)}, grid


def crop(P, sim, grid, label):
    """The dock's left half and the wallpaper round it, at 2 px a dp, labelled."""
    P2 = {**P, "ppd": 2.0}
    image = Image.fromarray((np.clip(slab.compose(P2, sim, grid), 0, 1) * 255 + 0.5).astype(np.uint8))
    out = image.crop((0, 776, 980, 1040))
    ImageDraw.Draw(out).text((8, 6), label, fill=(255, 255, 255))
    return out


def main():
    base, other, path = sys.argv[1:4]
    rows = []
    for k, step in enumerate(sys.argv[4:]):
        a, b = (float(v) for v in step.split(":"))
        P, sim, grid = mixed([(base, a), (other, b)])
        rows.append(crop(P, sim, grid, f"{k}   ({base} x{a:g} + {other} x{b:g})"))
        print(k, flush=True)
    sheet = Image.new("RGB", (980, len(rows) * 270), (40, 40, 40))
    for i, row in enumerate(rows):
        sheet.paste(row, (0, i * 270))
    sheet.save(path)


if __name__ == "__main__":
    main()
