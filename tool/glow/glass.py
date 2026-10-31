"""The dock's glass as a real object, traced as light goes through it.

A strip of clear cut glass, polished on both faces, its top and bottom edges
cut square with small polished bevels (arrises); behind each app an etched
(frosted) pad on its back; a thin air gap behind it, then a diffusing foil;
behind the foil, a hot lamp under the app in focus; further back, the
wallpaper.

The foil softens everything seen through the dock: it passes most light into
a narrow cone about its direction and the rest in all directions, and sends a
little back. Clear glass passes the foil's light straight through. The lamp's
light reaching the etched pad behind the app refracts through its rough
surface (GGX microfacets) with a spread, and what bends steeply enough is
trapped by total internal reflection: clear glass carries it along the dock,
out through the arrises (lighting the edges up), into the other pads (which
glow faintly behind their apps) and, a little at a time, back out through the
pads and edges. Light leaving the glass's back meets the foil again, which
returns some of it; the rest, the foil's reflection and the lamp's own back
fall on the wallpaper, which glows around the dock and through it.

The camera looks straight at the screen; its radiance is estimated from the
light leaving within a narrow cone about the view direction. The wallpaper
seen through the dock is convolved with the dock's response to a point of
light behind it, traced the same way.

  python3 glass.py params.json out_prefix
"""

import json
import sys

import numpy as np
from PIL import Image

import fake
import frost
import guide
import slab
from slab import BIN, blackbody_rgb, fft_convolve, gaussian_kernel, srgb_to_linear

LUMA = np.array([0.2126, 0.7152, 0.0722])

DEFAULTS = {
    **frost.DEFAULTS,
    # The back: its roughness outside the pads (0: polished), the pads'
    # roughness, and how far a pad reaches past its app's tile (dp).
    "frost": 0.0,
    "pad_frost": 0.6,
    "pad_margin": 0.0,
    # The foil: the air gap to it (dp; 0 for no foil), the share of light it
    # lets through, the all-directions part of that, the narrow cone's spread
    # (degrees), and the share it sends back.
    "foil_gap": 4.0,
    "foil_transmit": 0.8,
    "foil_wide": 0.35,
    "foil_cone": 12.0,
    "foil_reflect": 0.15,
    # Light going back and forth between glass and foil: how many times followed.
    "generations": 3,
}


def cosine(rng, k, sign):
    """k directions spread as a Lambertian surface sends them, toward sign * z."""
    dx, dy, dz = frost.cosine_dirs(rng, k)
    return dx, dy, dz * sign


def narrow(rng, dx, dy, dz, cone):
    """Directions turned a little at random (a Gaussian of slopes, cone degrees)."""
    t = np.tan(np.radians(cone))
    sx = dx / np.abs(dz) + rng.normal(0, t, dx.size)
    sy = dy / np.abs(dz) + rng.normal(0, t, dx.size)
    n = np.sqrt(sx * sx + sy * sy + 1)
    return sx / n, sy / n, np.sign(dz) / n


class Dock:
    """Light between the wallpaper and the camera: the foil, the glass and the
    wallpaper's plane, followed generation by generation as it goes back and
    forth. on_image(x, y, dirz, w) gets light leaving the glass toward the
    camera; on_wall(x, y, w) light landing on the wallpaper."""

    def __init__(self, P, rng, slab_, rows, alpha_at, on_image, on_wall, x_range):
        self.P, self.rng, self.slab, self.rows = P, rng, slab_, rows
        self.alpha_at, self.on_image, self.on_wall, self.x_range = alpha_at, on_image, on_wall, x_range
        self.forward, self.back = [], []  # batches heading to the glass / to the wallpaper

    def send_forward(self, x, y, z, dx, dy, dz, w):
        if x.size:
            self.forward.append((x, y, z, dx, dy, dz, w))

    def send_back(self, x, y, z, dx, dy, dz, w):
        if x.size:
            self.back.append((x, y, z, dx, dy, dz, w))

    def run(self):
        P, rng = self.P, self.rng
        gap = P["foil_gap"]
        for _ in range(P["generations"] + 1):
            forward, self.forward = self.forward, []
            for x, y, z, dx, dy, dz, w in forward:
                if gap > 0 and z < -gap:
                    # Through the foil from behind.
                    s = (-gap - z) / dz
                    x, y = x + dx * s, y + dy * s
                    r = rng.random(x.size)
                    t = r < P["foil_transmit"]
                    back = (r >= P["foil_transmit"]) & (r < P["foil_transmit"] + P["foil_reflect"])
                    wide = t & (rng.random(x.size) < P["foil_wide"])
                    nd = narrow(rng, dx, dy, dz, P["foil_cone"])
                    cd = cosine(rng, x.size, 1.0)
                    ndx = np.where(wide, cd[0], nd[0])
                    ndy = np.where(wide, cd[1], nd[1])
                    ndz = np.where(wide, cd[2], nd[2])
                    self.enter(x[t], y[t], ndx[t], ndy[t], ndz[t], w[t], gap)
                    bd = cosine(rng, back.sum(), -1.0)
                    self.land(x[back], y[back], np.full(back.sum(), -gap), *bd, w[back])
                else:
                    self.enter(x, y, dx, dy, dz, w, -z)
            back, self.back = self.back, []
            for x, y, z, dx, dy, dz, w in back:
                if gap > 0 and z > -gap:
                    # Meeting the foil from the glass's side.
                    s = (z + gap) / -dz
                    x, y = x + dx * s, y + dy * s
                    r = rng.random(x.size)
                    t = r < P["foil_transmit"]
                    ret = (r >= P["foil_transmit"]) & (r < P["foil_transmit"] + P["foil_reflect"])
                    wide = t & (rng.random(x.size) < P["foil_wide"])
                    nd = narrow(rng, dx, dy, dz, P["foil_cone"])
                    cd = cosine(rng, x.size, -1.0)
                    bdx = np.where(wide, cd[0], nd[0])
                    bdy = np.where(wide, cd[1], nd[1])
                    bdz = np.where(wide, cd[2], nd[2])
                    self.land(x[t], y[t], np.full(t.sum(), -gap), bdx[t], bdy[t], bdz[t], w[t])
                    fd = cosine(rng, ret.sum(), 1.0)
                    self.send_forward(x[ret], y[ret], np.full(ret.sum(), -gap), *fd, w[ret])
                else:
                    self.land(x, y, z, dx, dy, dz, w)

    def land(self, x, y, z, dx, dy, dz, w):
        """Light heading back, landing on the wallpaper's plane."""
        s = (z + self.P["wall_gap"]) / -dz
        self.on_wall(x + dx * s, y + dy * s, w)

    def enter(self, x, y, dx, dy, dz, w, distance):
        """Light crossing the air gap (distance) to the glass's back."""
        P, rng = self.P, self.rng
        s = distance / dz
        x, y = x + dx * s, y + dy * s
        if self.rows is not None:
            k = P["arris"]
            on = (y > self.rows[0] + k) & (y < self.rows[1] - k)
            x, y, dx, dy, dz, w = x[on], y[on], dx[on], dy[on], dz[on], w[on]
        if x.size == 0:
            return
        alpha = self.alpha_at(x, y)
        ox, oy, oz, crossed, ok = frost.rough(dx, dy, dz, alpha, 1.0, P["ior"], rng)
        refl = ok & ~crossed
        self.send_back(x[refl], y[refl], np.zeros(refl.sum()), ox[refl], oy[refl], oz[refl], w[refl])
        go = ok & crossed
        cone = np.cos(np.radians(P["view_cone"]))

        def on_exit(ex, ey, ez, edx, edy, edz, ew):
            seen = edz > cone
            if seen.any():
                self.on_image(ex[seen], ey[seen], ew[seen])
            down = edz < 0
            self.send_back(ex[down], ey[down], ez[down], edx[down], edy[down], edz[down], ew[down])

        frost.trace(self.slab, x[go], y[go], np.zeros(go.sum()), ox[go], oy[go], oz[go], w[go], P, rng,
                    on_exit, self.x_range, self.alpha_at)


def simulate(P):
    rng = np.random.default_rng(P["seed"])
    x0, y0 = -40.0, fake.DOCK_TOP
    W, H = int((1000 - x0) / BIN), int(round(fake.DOCK_H / BIN))
    grid = (x0, y0, H, W)
    rows = (y0, y0 + H * BIN)
    sw, sh = round(960 / BIN), round(540 / BIN)
    r0, c0 = int(round(y0 / BIN)), int(round(-x0 / BIN))
    radiance = 1 / (BIN * BIN * np.pi * np.sin(np.radians(P["view_cone"])) ** 2)

    wall_img = Image.open(P["wallpaper"]).convert("RGB")
    wall_srgb = np.asarray(wall_img.resize((sw, sh), Image.LANCZOS), float) / 255
    wall_full = srgb_to_linear(wall_srgb)

    def band(full):
        out = np.zeros((H, W, full.shape[2]))
        out[:, c0:c0 + sw] = full[r0:r0 + H, : W - c0]
        return out

    # The etched pads, one behind each app.
    pads = []
    for i in range(6):
        tx, ty, tw, th = fake.tile_rect(i)
        m = P["pad_margin"]
        pads.append((tx - m, ty - m, tx + tw + m, ty + th + m, fake.RADIUS + m))

    def alpha_at(x, y):
        a = np.full(x.size, float(P["frost"]))
        for left, top, right, bottom, r in pads:
            ddx = np.maximum(np.maximum(left + r - x, x - (right - r)), 0)
            ddy = np.maximum(np.maximum(top + r - y, y - (bottom - r)), 0)
            inside = (x > left) & (x < right) & (y > top) & (y < bottom) & (ddx * ddx + ddy * ddy < r * r)
            a[inside] = P["pad_frost"]
        return a

    # The hot lamp, under the selected app.
    tx, ty, tw, th = fake.tile_rect(P["selected"])
    cx, cy = tx + tw / 2, ty + th / 2
    s = P["light_scale"]
    if P["light_shape"] == "tube":
        lw, lh = tw * s, P["light_tube"]
        lr = lh / 2
    elif P["light_shape"] == "disc":
        lw = lh = th * s
        lr = lh / 2
    else:
        lw, lh, lr = tw * s, th * s, fake.RADIUS * s
    colour = blackbody_rgb(P["light_temp"]) * P["light_radiance"]
    sx, sy = (np.arange(sw) + 0.5) * BIN, (np.arange(sh) + 0.5) * BIN
    ddx = np.maximum(np.abs(sx[None, :] - cx) - (lw / 2 - lr), 0)
    ddy = np.maximum(np.abs(sy[:, None] - cy) - (lh / 2 - lr), 0)
    mask_full = np.clip(lr + 0.5 * BIN - np.sqrt(ddx * ddx + ddy * ddy), 0, BIN) / BIN
    if P["light_soft"] > 0:
        mask_full = fft_convolve(mask_full, gaussian_kernel(P["light_soft"], BIN))

    # The glow: the lamp's light, traced.
    image = np.zeros((H * W, 3))
    wall_flux = np.zeros((sh * sw, 3))

    def on_image(x, y, w):
        jx = np.clip(((x - x0) / BIN).astype(int), 0, W - 1)
        jy = np.clip(((y - y0) / BIN).astype(int), 0, H - 1)
        for c in range(3):
            image[:, c] += np.bincount(jy * W + jx, w[:, c] * radiance, minlength=H * W)

    def on_wall(x, y, w):
        jx, jy = (x / BIN).astype(int), (y / BIN).astype(int)
        ok = (jx >= 0) & (jx < sw) & (jy >= 0) & (jy < sh)
        for c in range(3):
            wall_flux[:, c] += np.bincount(jy[ok] * sw + jx[ok], w[ok, c], minlength=sh * sw)

    N = int(P["rays"])
    prob = mask_full.ravel() / mask_full.sum()
    cells = np.minimum(np.searchsorted(np.cumsum(prob), rng.random(N)), prob.size - 1)
    iy, ix = np.divmod(cells, sw)
    lx, ly = (ix + rng.random(N)) * BIN, (iy + rng.random(N)) * BIN
    dx, dy, dz = frost.cosine_dirs(rng, N)
    w = np.tile(np.pi * colour * mask_full.sum() * BIN * BIN / N, (N, 1))
    dock = Dock(P, rng, frost.Slab(P, rows), rows, alpha_at, on_image, on_wall, (x0 - 300, x0 + W * BIN + 300))
    dock.send_forward(lx, ly, np.full(N, -P["light_gap"]), dx, dy, dz, w)
    dock.run()

    smooth_k = gaussian_kernel(P["smooth"], BIN)
    glow_band = fft_convolve(image.reshape(H, W, 3), smooth_k)
    gap = P["wall_gap"]
    falling = fft_convolve(wall_flux.reshape(sh, sw, 3), smooth_k) / (BIN * BIN)
    falling += P["light_back"] * fft_convolve(mask_full, guide.kernel(gap - P["light_gap"]))[..., None] * colour
    lum = wall_srgb @ LUMA
    tint = wall_full / np.maximum(wall_full @ LUMA, 1e-4)[..., None]
    albedo = P["wall_albedo"] * (P["wall_albedo_dark"] + (1 - P["wall_albedo_dark"]) * lum)[..., None]
    albedo = albedo * (0.7 + 0.3 * np.clip(tint, 0, 3))
    bleed = falling * albedo / np.pi

    # What the dock does to a point of light on the wallpaper (clear glass,
    # infinite): to convolve the wallpaper and its glow with.
    rx, ry = int(160 / BIN), int(80 / BIN)
    psf = np.zeros((2 * ry + 1, 2 * rx + 1))

    def psf_image(x, y, w):
        jx, jy = np.round(x / BIN).astype(int) + rx, np.round(y / BIN).astype(int) + ry
        ok = (jx >= 0) & (jx <= 2 * rx) & (jy >= 0) & (jy <= 2 * ry)
        np.add.at(psf, (jy[ok], jx[ok]), w[ok, 0] * radiance)

    Np = int(P["psf_rays"])
    clear = lambda x, y: np.full(x.size, float(P["frost"]))
    probe = Dock(P, rng, frost.Slab(P), None, clear, psf_image, lambda x, y, w: None, (-200, 200))
    pdx, pdy, pdz = frost.cosine_dirs(rng, Np)
    probe.send_forward((rng.random(Np) - 0.5) * BIN, (rng.random(Np) - 0.5) * BIN, np.full(Np, -gap), pdx, pdy, pdz,
                       np.full((Np, 1), np.pi * BIN * BIN / Np))
    probe.run()

    glass_band = band(fft_convolve(wall_full, psf))
    glow_band += band(fft_convolve(bleed, psf))
    outside = np.ones((sh, 1))
    outside[r0:r0 + H] = 0
    glow_full = bleed + mask_full[..., None] * colour * outside[..., None]
    return {"glass": (glass_band, wall_full), "glow": (glow_band, glow_full)}, grid


if __name__ == "__main__":
    P = {**DEFAULTS, **json.load(open(sys.argv[1]))}
    sim, grid = simulate(P)
    np.save(sys.argv[2] + "-glow.npy", sim["glow"][0])
    fake.save(slab.compose(P, sim, grid), sys.argv[2] + ".png")
