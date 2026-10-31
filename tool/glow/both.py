"""Two of guide.py's looks lit at once: one setup's glow plus a share of
another's (light adds), over the first's glass.

  python3 both.py base.json first.json second.json share out.png [crop]
first and second hold each look's own parameters over base.
"""

import json
import sys

import numpy as np
from PIL import Image

import fake
import guide
import slab

base = json.load(open(sys.argv[1]))
first = {**guide.DEFAULTS, **base, **json.load(open(sys.argv[2]))}
second = {**guide.DEFAULTS, **base, **json.load(open(sys.argv[3]))}
share = float(sys.argv[4])
a, grid = guide.simulate(first)
b, _ = guide.simulate(second)
glow = (a["glow"][0] + share * b["glow"][0], a["glow"][1] + share * b["glow"][1])
image = slab.compose(first, {"glass": a["glass"], "glow": glow}, grid)
out = Image.fromarray((np.clip(image, 0, 1) * 255 + 0.5).astype(np.uint8))
if len(sys.argv) > 6 and sys.argv[6] == "dock":
    ppd = first["ppd"]
    out = out.crop((0, round(380 * ppd), round(960 * ppd), round(530 * ppd))).resize((1440, 225), Image.LANCZOS)
out.save(sys.argv[5])
