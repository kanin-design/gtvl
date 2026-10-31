"""Fits the cheap glow the app draws to a glow traced by guide.py, and renders
the two side by side.

The fake is a sum of a few closed-form shapes centred on the lamp (the app
in focus), in linear light, with the reference's blackbody colour:
  core   the lamp seen through the foil: a box blurred by a Gaussian
         (an erf across times an erf down);
  pool   the foil's wide light around it: 1 / (1 + (d/s)^2)^p, d the
         distance outside the lamp's rounded rectangle;
  glass  light carried along the glass: exp(-dx / L), dx the distance
         along the dock beyond the lamp;
  edges  the cut top and bottom edges (their outer dp): exp(-dx / L);
  bleed  the wallpaper's glow beyond the dock: 1 / (1 + (d/s)^2)^p.
Amplitudes are solved by least squares in linear light, each value weighted
by how much it shows on screen (the slope of the tone curve), outside the
tiles; the shape numbers are found by a search from a start. The app's
shader computes the same formulas.

  python3 fit.py look.json name
look.json: guide.py parameters over its defaults ("wallpaper" and "tiles"
paths included), or {"mix": [[look, share], ...]}: traced looks lit together
(ladder.py). Writes looks/<name>-fake.json and out/<name>-*.png.
"""

import json
import os
import sys

import numpy as np
from PIL import Image

import fake
import guide
import ladder
import look
import slab
from slab import BIN

HERE = os.path.dirname(os.path.abspath(__file__))
LUMA = np.array([0.2126, 0.7152, 0.0722])
EXPOSURE = 3.0


def erf(x):
    """Abramowitz and Stegun 7.1.26 (error under 1.5e-7), as the shader has it."""
    s = np.sign(x)
    x = np.abs(x)
    t = 1 / (1 + 0.3275911 * x)
    y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * np.exp(-x * x)
    return s * y


def box(u, half, sigma):
    """A box of half-width half, blurred by a Gaussian of sigma: 1 inside, 0 far out."""
    k = 1 / (np.sqrt(2) * sigma)
    return 0.5 * (erf((u + half) * k) - erf((u - half) * k))


def outside(x, y, hw, hh, r):
    """Distance outside a rounded rectangle of half-sizes hw, hh centred at 0 (0 inside)."""
    qx, qy = np.abs(x) - (hw - r), np.abs(y) - (hh - r)
    return np.maximum(np.sqrt(np.maximum(qx, 0) ** 2 + np.maximum(qy, 0) ** 2) - r, 0)


class Fake:
    """The fake's shapes for one lamp, over the dock's band and the screen."""

    def __init__(self, P, grid):
        x0, y0, H, W = grid
        tx, ty, tw, th = fake.tile_rect(P["selected"])
        s = P["light_scale"]
        self.cx, self.cy = tx + tw / 2, ty + th / 2
        self.hw, self.hh, self.r = tw * s / 2, th * s / 2, fake.RADIUS * s
        self.top, self.bottom = y0, y0 + H * BIN
        bx = x0 + (np.arange(W) + 0.5) * BIN - self.cx
        by = y0 + (np.arange(H) + 0.5) * BIN - self.cy
        self.bx, self.by = np.meshgrid(bx, by)
        self.bd = outside(self.bx, self.by, self.hw, self.hh, self.r)
        self.bdx = np.maximum(np.abs(self.bx) - self.hw, 0)
        rows = by + self.cy
        self.edge_rows = ((rows - self.top < 1.0) | (self.bottom - rows < 1.0)).astype(float)[:, None]
        sw, sh = round(960 / BIN), round(540 / BIN)
        fx, fy = np.meshgrid((np.arange(sw) + 0.5) * BIN - self.cx, (np.arange(sh) + 0.5) * BIN - self.cy)
        self.fd = outside(fx, fy, self.hw, self.hh, self.r)

    def band(self, q):
        """The band's shapes for shape numbers q, one per row of the result."""
        core = box(self.bx, self.hw, q["core_blur"]) * box(self.by, self.hh, q["core_blur"])
        pool = (1 + (self.bd / q["pool_size"]) ** 2) ** -q["pool_power"]
        glass = np.exp(-self.bdx / q["glass_length"])
        edges = self.edge_rows * np.exp(-self.bdx / q["edge_length"])
        return np.stack([core, pool, glass, edges])

    def bleed(self, q):
        return (1 + (self.fd / q["bleed_size"]) ** 2) ** -q["bleed_power"]


def solve(shapes, target, weight):
    """Non-negative amplitudes of shapes (k x ...) best matching target, weighted."""
    A = shapes.reshape(len(shapes), -1).T * np.sqrt(weight.ravel())[:, None]
    b = target.ravel() * np.sqrt(weight.ravel())
    on = list(range(len(shapes)))
    while True:
        a = np.zeros(len(shapes))
        a[on] = np.linalg.lstsq(A[:, on], b, rcond=None)[0]
        bad = [i for i in on if a[i] < 0]
        if not bad:
            return a
        on = [i for i in on if i not in bad]


def main():
    given = json.load(open(sys.argv[1]))
    P = {**guide.DEFAULTS, **given}
    name = sys.argv[2]
    out = os.path.join(HERE, "out")
    cache = os.path.join(out, f"{name}-ref.npz")
    if "mix" in given:
        P, sim, grid = ladder.mixed(given["mix"])
    elif os.path.exists(cache):
        z = np.load(cache)
        sim = {"glass": (z["glass_band"], z["wall_full"]), "glow": (z["glow_band"], z["glow_full"])}
        grid = tuple(z["grid"])
        grid = (float(grid[0]), float(grid[1]), int(grid[2]), int(grid[3]))
    else:
        sim, grid = guide.simulate(P)
        np.savez(cache, glass_band=sim["glass"][0], wall_full=sim["glass"][1], glow_band=sim["glow"][0],
                 glow_full=sim["glow"][1], grid=np.array(grid))
    x0, y0, H, W = grid
    F = Fake(P, grid)
    ref_band = sim["glow"][0] @ LUMA
    ref_full = sim["glow"][1] @ LUMA

    # Where the fit looks: the screen's part of the band outside the tiles;
    # the screen outside the band, near the dock, for the bleed.
    xs = x0 + (np.arange(W) + 0.5) * BIN
    ys = y0 + (np.arange(H) + 0.5) * BIN
    seen = ((xs >= 0) & (xs < 960))[None, :] & np.ones((H, 1), bool)
    for i in range(6):
        tx, ty, tw, th = fake.tile_rect(i, lifted=i == P["selected"])
        seen &= ~(((xs >= tx) & (xs < tx + tw))[None, :] & ((ys >= ty) & (ys < ty + th))[:, None])
    w_band = seen * EXPOSURE * np.exp(-EXPOSURE * ref_band)
    sh, sw = ref_full.shape
    fy = (np.arange(sh) + 0.5) * BIN
    near = ((fy < F.top) & (fy > F.top - 160)) | ((fy > F.bottom) & (fy < F.bottom + 60))
    w_full = near[:, None] * np.ones((1, sw)) * EXPOSURE * np.exp(-EXPOSURE * ref_full)

    def error(q):
        shapes = F.band(q)
        a = solve(shapes, ref_band, w_band)
        fit = np.tensordot(a, shapes, 1)
        b = F.bleed(q)
        ab = solve(b[None], ref_full, w_full)[0]
        e_band = (look.tone(fit, EXPOSURE) - look.tone(ref_band, EXPOSURE)) ** 2
        e_full = (look.tone(ab * b, EXPOSURE) - look.tone(ref_full, EXPOSURE)) ** 2
        err = np.sqrt((e_band * seen).sum() / seen.sum()) + np.sqrt((e_full * near[:, None]).sum() / (near.sum() * sw))
        return err, a, ab

    q = {"core_blur": 6.0, "pool_size": 15.0, "pool_power": 1.5, "glass_length": 60.0, "edge_length": 150.0,
         "bleed_size": 30.0, "bleed_power": 1.5}
    best = error(q)[0]
    for _ in range(4):
        for key in q:
            for f in (0.5, 0.7, 0.85, 1.18, 1.4, 2.0):
                trial = {**q, key: q[key] * f}
                e = error(trial)[0]
                if e < best:
                    best, q = e, trial
        print("error %.4f" % best, {k: round(v, 2) for k, v in q.items()}, flush=True)
    err, a, ab = error(q)

    # The fake's light, in the reference's colours, put together as the reference is.
    colour = slab.blackbody_rgb(P["light_temp"])
    shapes = F.band(q)
    fake_band = np.tensordot(a, shapes, 1)[..., None] * colour
    ref_rgb, ref_l = sim["glow"][1].reshape(-1, 3), ref_full.ravel()
    wb = w_full.ravel()
    bleed_colour = (ref_rgb * wb[:, None]).sum(0) / max((ref_l * wb).sum(), 1e-12)
    fake_full = (ab * F.bleed(q))[..., None] * bleed_colour
    result = {
        "light_temp": P["light_temp"], "light_scale": P["light_scale"], "exposure": EXPOSURE,
        "core": a[0], "pool": a[1], "glass": a[2], "edges": a[3], "bleed": ab,
        "bleed_colour": list(bleed_colour), **q, "error": err,
    }
    json.dump(result, open(os.path.join(HERE, "looks", f"{name}-fake.json"), "w"), indent=1)
    print(json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in result.items()}))

    P2 = {**P, "ppd": 2.0}
    ref_img = slab.compose(P2, sim, grid)
    fake_img = slab.compose(P2, {"glass": sim["glass"], "glow": (fake_band, fake_full)}, grid)
    fake.save(ref_img, os.path.join(out, f"{name}-reference.png"))
    fake.save(fake_img, os.path.join(out, f"{name}-fake.png"))
    crops = [Image.fromarray((np.clip(i, 0, 1) * 255 + 0.5).astype(np.uint8)).crop((0, 720, 1920, 1080))
             for i in (ref_img, fake_img)]
    pair = Image.new("RGB", (1920, 726), (90, 90, 90))
    pair.paste(crops[0], (0, 0))
    pair.paste(crops[1], (0, 366))
    pair.save(os.path.join(out, f"{name}-pair.png"))


if __name__ == "__main__":
    main()
