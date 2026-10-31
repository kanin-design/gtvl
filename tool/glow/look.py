"""How GTVL shows the glass's light: a film-like response, per colour
channel, from linear light to what is added onto the screen. Dim light keeps
the light's colour (deep orange); bright light saturates channel by channel,
through yellow, to white-hot, as a hot glow does to the eye.

The app's own glow uses the same curve, so a render and the app compare
directly.
"""

import sys

import numpy as np
from PIL import Image


def tone(light, exposure):
    """Linear light (H x W x 3) to display values 0..1."""
    return 1.0 - np.exp(-exposure * np.maximum(light, 0.0))


def save(light, exposure, path):
    Image.fromarray((tone(light, exposure) * 255 + 0.5).astype(np.uint8)).save(path)


def sheet(entries, exposure, path, scale=2, gap=6):
    """Stacks renders (name, light) into one image, each enlarged by scale."""
    images = [Image.fromarray((tone(l, exposure) * 255 + 0.5).astype(np.uint8)) for _, l in entries]
    w = max(i.width for i in images) * scale
    h = sum(i.height * scale + gap for i in images)
    out = Image.new("RGB", (w, h), (36, 36, 40))
    y = 0
    for image in images:
        out.paste(image.resize((image.width * scale, image.height * scale), Image.LANCZOS), (0, y))
        y += image.height * scale + gap
    out.save(path)


if __name__ == "__main__":
    exposure = float(sys.argv[1])
    out = sys.argv[2]
    sheet([(p, np.load(p)) for p in sys.argv[3:]], exposure, out)
