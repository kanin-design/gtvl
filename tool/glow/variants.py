"""Renders glow variants quickly and lays them out on one sheet, each over
the same glass pass, for choosing between them.

  python3 variants.py glass.png exposure sheet.png base.json name=extra.json ...
base.json holds the parameters shared by all; each extra holds one
variant's own, as JSON.
"""

import json
import os
import subprocess
import sys

from PIL import Image, ImageDraw

import combine

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
HERE = os.path.dirname(os.path.abspath(__file__))

glass, exposure, sheet_path, base = sys.argv[1], float(sys.argv[2]), sys.argv[3], json.loads(sys.argv[4])
work = os.path.dirname(sheet_path)
crops = []
for arg in sys.argv[5:]:
    name, extra = arg.split("=", 1)
    params = {**base, **json.loads(extra), "pass": "glow", "out": f"{work}/{name}"}
    subprocess.run([BLENDER, "-b", "--factory-startup", "--python", f"{HERE}/scene.py", "--", json.dumps(params)],
                   check=True, capture_output=True)
    image = Image.fromarray((combine.combine(glass, f"{work}/{name}.npy", exposure) * 255 + 0.5).astype("uint8"))
    ppd = image.width / 960
    crop = image.crop((0, round(380 * ppd), round(700 * ppd), round(540 * ppd))).resize((1050, 240), Image.LANCZOS)
    ImageDraw.Draw(crop).text((8, 6), f"{name}: {extra}", fill=(255, 255, 255))
    crops.append(crop)
    print(name, "done", flush=True)
out = Image.new("RGB", (1050, len(crops) * 246), (40, 40, 40))
for i, crop in enumerate(crops):
    out.paste(crop, (0, i * 246))
out.save(sheet_path)
