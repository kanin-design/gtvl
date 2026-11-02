"""Runs slab.py's simulation for several variants and lays their docks out on
one sheet, labelled, for choosing between them.

  python3 sheet.py base.json sheet.png name='{"param": value}' ...
"""

import json
import sys

import numpy as np
from PIL import Image, ImageDraw

import fake
import frost
import glass
import guide
import slab

# --guide, --frost or --glass: that model instead of the laminated one (slab.py).
model = {"--guide": guide, "--frost": frost, "--glass": glass}.get(sys.argv[1], slab)
if model is not slab:
    sys.argv = [sys.argv[0], *sys.argv[2:]]
base = {**model.DEFAULTS, **json.load(open(sys.argv[1]))}
out_path = sys.argv[2]
crops = []
for arg in sys.argv[3:]:
    name, extra = arg.split("=", 1)
    P = {**base, **json.loads(extra)}
    sim, grid = model.simulate(P)
    image = slab.compose(P, sim, grid)
    ppd = P["ppd"]
    crop = Image.fromarray((np.clip(image, 0, 1) * 255 + 0.5).astype(np.uint8))
    crop = crop.crop((0, round(380 * ppd), round(960 * ppd), round(530 * ppd))).resize((1440, 225), Image.LANCZOS)
    ImageDraw.Draw(crop).text((8, 6), f"{name}: {extra}", fill=(255, 255, 255))
    crops.append(crop)
    print(name, flush=True)
sheet = Image.new("RGB", (1440, len(crops) * 231), (40, 40, 40))
for i, crop in enumerate(crops):
    sheet.paste(crop, (0, i * 231))
sheet.save(out_path)
