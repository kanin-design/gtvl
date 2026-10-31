"""Renders guide.py variants cropped exactly like the user's two picks (the
dock's band from 360 to 540 dp, 1440 x 270), labelled, stacked on one sheet.

  python3 originals.py base.json sheet.png name='{"param": value}' ...
"""

import json
import sys

import numpy as np
from PIL import Image, ImageDraw

import guide
import slab

base = {**guide.DEFAULTS, **json.load(open(sys.argv[1]))}
crops = []
for arg in sys.argv[3:]:
    name, extra = arg.split("=", 1)
    P = {**base, **json.loads(extra)}
    sim, grid = guide.simulate(P)
    image = Image.fromarray((np.clip(slab.compose(P, sim, grid), 0, 1) * 255 + 0.5).astype(np.uint8))
    ppd = P["ppd"]
    crop = image.crop((0, round(360 * ppd), round(960 * ppd), round(540 * ppd))).resize((1440, 270), Image.LANCZOS)
    ImageDraw.Draw(crop).text((8, 6), name, fill=(255, 255, 255))
    crops.append(crop)
    print(name, flush=True)
sheet = Image.new("RGB", (1440, len(crops) * 276), (40, 40, 40))
for i, crop in enumerate(crops):
    sheet.paste(crop, (0, i * 276))
sheet.save(sys.argv[2])
