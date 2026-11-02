"""The dock as a slab of cut glass with a diffusing foil laminated to its back,
lit from behind by the wallpaper and by a hot light under the app in focus:
a light-transport simulation of that one object, rather than a general
raytrace, and the home screen put together around it.

The foil scatters light passing through it in two ways: most of it a little
(a narrow cone, which softens what lies behind by an amount that grows with
its distance, as frosted film does) and the rest in all directions (into the
glass as a Lambertian spread). The narrow part shows the wallpaper softly
blurred and the nearby hot light almost sharp; it is worked out exactly as
blurs. The wide part is traced ray by ray inside the glass: within the
escape cone it leaves through the polished front; beyond it, it is trapped
by total internal reflection and travels along the slab, returning to the
foil (where some is lost through its back and the rest is scattered again)
until it escapes through the front or through the polished cut edges at the
top and bottom, which is what lights them up. The hot light also lights the
wallpaper's surface behind it, which shows around and through the glass.

Light is linear; the screen shows the wallpaper and glass as they are and
adds the hot light's share through look.tone, as the app adds its glow.

  python3 slab.py params.json out_prefix
"""

import json
import sys

import numpy as np
from PIL import Image

import fake
import look

DEFAULTS = {
    "wallpaper": "",
    "tiles": "",
    "selected": 1,
    "ppd": 2.0,
    # The glass and its foil.
    "thickness": 5.0,
    "ior": 1.5,
    "foil_transmit": 0.85,  # of light reaching the foil from behind, the share let into the glass
    "foil_wide": 0.35,  # of that, the share scattered in all directions (the rest: a narrow cone)
    "foil_cone": 12.0,  # the narrow cone's spread, degrees (standard deviation, in air)
    "foil_loss": 0.35,  # of light reaching the foil from inside, the share lost through its back
    "foil_absorb": 0.05,  # ... and the share it absorbs
    "edge_scatter": 0.25,  # of light leaving a cut edge, the share its finish sends toward the viewer
    "edge_width": 1.0,  # dp
    # Distances behind the foil.
    "wall_gap": 40.0,
    "light_gap": 12.0,
    # The hot light: size against the tile's, colour temperature, radiance.
    "light_scale": 1.0,
    "light_temp": 2300.0,
    "light_radiance": 1.0,
    # The wallpaper's surface: how much light falling on it it gives back,
    # at its darkest and (scaled by its own brightness) at its brightest.
    "wall_albedo": 0.5,
    "wall_albedo_dark": 0.3,
    # The tiles' edges: how much of the glow behind them they catch.
    "tile_rim": 0.25,
    # Smoothing of the traced light, dp (it is smooth; the trace is grainy).
    "smooth": 0.75,
    # Rays traced for the wide share, and the screen's exposure for the glow.
    "rays": 3_000_000,
    "exposure": 3.0,
    "seed": 1,
}

BIN = 0.5  # dp per simulation cell


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def blackbody_rgb(temperature):
    """A blackbody's colour as linear sRGB with luminance 1 (CIE 1931 2-degree
    observer, from Wyman, Sloan and Shirley's fit)."""
    lam = np.arange(380.0, 781.0, 1.0)

    def g(x, mu, s1, s2):
        return np.exp(-0.5 * ((x - mu) / np.where(x < mu, s1, s2)) ** 2)

    xbar = 1.056 * g(lam, 599.8, 37.9, 31.0) + 0.362 * g(lam, 442.0, 16.0, 26.7) - 0.065 * g(lam, 501.1, 20.4, 26.2)
    ybar = 0.821 * g(lam, 568.8, 46.9, 40.5) + 0.286 * g(lam, 530.9, 16.3, 31.1)
    zbar = 1.217 * g(lam, 437.0, 11.8, 36.0) + 0.681 * g(lam, 459.0, 26.0, 13.8)
    h, c, k = 6.626e-34, 2.998e8, 1.381e-23
    m = lam * 1e-9
    planck = 1 / (m**5 * (np.exp(h * c / (m * k * temperature)) - 1))
    X, Y, Z = (np.sum(planck * bar) for bar in (xbar, ybar, zbar))
    rgb = np.array([[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]]) @ [X, Y, Z]
    rgb = np.clip(rgb, 0, None)
    return rgb / (rgb @ [0.2126, 0.7152, 0.0722])


def fft_convolve(image, kernel):
    """image (H x W [x C]) convolved with a centred kernel (h x w, odd), zero outside."""
    H, W = image.shape[:2]
    h, w = kernel.shape
    shape = (H + h, W + w)
    K = np.fft.rfft2(kernel, shape)
    if image.ndim == 2:
        out = np.fft.irfft2(np.fft.rfft2(image, shape) * K, shape)
        return out[h // 2:h // 2 + H, w // 2:w // 2 + W]
    return np.stack([fft_convolve(image[..., c], kernel) for c in range(image.shape[2])], axis=-1)


def irradiance_kernel(distance, cell):
    """Irradiance on a plane from a unit-radiance Lambertian patch on a parallel
    plane [distance] away, per cell of area cell^2: d^2 / (d^2 + r^2)^2. It
    sums to pi over the whole plane, as a wall filling the view gives E = pi L."""
    r = int(np.ceil(distance * 12 / cell))
    y, x = np.mgrid[-r:r + 1, -r:r + 1] * cell
    d2 = distance * distance
    return d2 / (d2 + x * x + y * y) ** 2 * cell * cell


def gaussian_kernel(sigma, cell):
    r = max(1, int(np.ceil(sigma * 3.5 / cell)))
    y, x = np.mgrid[-r:r + 1, -r:r + 1] * cell
    k = np.exp(-0.5 * (x * x + y * y) / max(sigma, 1e-6) ** 2)
    return k / k.sum()


def fresnel(cos_i, n1, n2):
    """Unpolarised reflectance going from index n1 into n2 at incidence cos_i;
    1 where light is totally internally reflected."""
    sin_t2 = (n1 / n2) ** 2 * (1 - cos_i * cos_i)
    tir = sin_t2 >= 1
    cos_t = np.sqrt(np.clip(1 - sin_t2, 0, 1))
    rs = ((n1 * cos_i - n2 * cos_t) / (n1 * cos_i + n2 * cos_t)) ** 2
    rp = ((n1 * cos_t - n2 * cos_i) / (n1 * cos_t + n2 * cos_i)) ** 2
    return np.where(tir, 1.0, 0.5 * (rs + rp))


def lambertian(rng, k):
    """k directions spread as a Lambertian surface sends them (towards +z)."""
    u1, u2 = rng.random(k), rng.random(k)
    sin_t, cos_t, phi = np.sqrt(1 - u1), np.sqrt(u1), 2 * np.pi * u2
    return sin_t * np.cos(phi), sin_t * np.sin(phi), cos_t


def trace(entering, grid, P, rng):
    """Traces the wide share of light entering the glass through the foil.

    entering: H x W x 3 flux per cell (from the foil's back into the glass,
    spread as a Lambertian surface). Returns the flux leaving the front per
    cell (H x W x 3) and leaving the top and bottom edges per column (W x 3 each).
    """
    x0, y0, H, W = grid
    t, n = P["thickness"], P["ior"]
    lum = entering @ [0.2126, 0.7152, 0.0722]
    total = lum.sum()
    front, leak = np.zeros((H * W, 3)), np.zeros((H * W, 3))
    top, bottom = np.zeros((W, 3)), np.zeros((W, 3))
    if total <= 0:
        return front.reshape(H, W, 3), top, bottom, leak.reshape(H, W, 3)
    N = int(P["rays"])
    cells = np.searchsorted(np.cumsum(lum.ravel()) / total, rng.random(N))
    cells = np.minimum(cells, H * W - 1)
    iy, ix = np.divmod(cells, W)
    x = x0 + (ix + rng.random(N)) * BIN
    y = y0 + (iy + rng.random(N)) * BIN
    weight = entering.reshape(-1, 3)[cells] / lum.ravel()[cells, None] * (total / N)
    dx, dy, dz = lambertian(rng, N)
    y_top, y_bottom = y0, y0 + H * BIN  # screen y grows downward: top edge has the smaller y

    def deposit(mask, px, py, into):
        jx = np.clip(((px[mask] - x0) / BIN).astype(int), 0, W - 1)
        jy = np.clip(((py[mask] - y0) / BIN).astype(int), 0, H - 1)
        for c in range(3):
            into[:, c] += np.bincount(jy * W + jx, weight[mask, c], minlength=H * W)

    alive = np.ones(N, bool)
    for _ in range(200):
        idx = np.nonzero(alive)[0]
        if idx.size == 0:
            break
        # Across the glass to the other face.
        s = t / np.abs(dz[idx])
        nx, ny = x[idx] + dx[idx] * s, y[idx] + dy[idx] * s
        ddy = dy[idx].copy()
        dead = np.zeros(idx.size, bool)
        # The cut edges: mirror back what they reflect, let out what they pass.
        for _ in range(64):
            out_top, out_bottom = ny < y_top, ny > y_bottom
            hit = (out_top | out_bottom) & ~dead
            if not hit.any():
                break
            edge = np.where(out_top, y_top, y_bottom)
            # Where the ray meets the edge, along x.
            frac = np.where(hit, (edge - (ny - ddy * s)) / np.where(ddy == 0, 1, ddy * s), 0)
            cross_x = nx - dx[idx] * s * (1 - np.clip(frac, 0, 1))
            cos_e = np.abs(ddy)
            reflect = rng.random(idx.size) < fresnel(cos_e, n, 1.0)
            leave = hit & ~reflect
            if leave.any():
                jx = np.clip(((cross_x[leave] - x0) / BIN).astype(int), 0, W - 1)
                w = weight[idx[leave]]
                for into, side in ((top, out_top[leave]), (bottom, ~out_top[leave])):
                    for c in range(3):
                        into[:, c] += np.bincount(jx[side], w[side, c], minlength=W)
                dead |= leave
            bounce = hit & reflect
            ny = np.where(bounce, 2 * edge - ny, ny)
            ddy = np.where(bounce, -ddy, ddy)
        dy[idx] = ddy
        x[idx], y[idx] = nx, np.clip(ny, y_top, y_bottom - 1e-6)
        alive[idx[dead]] = False
        idx_live = idx[~dead]
        going_front = dz[idx_live] > 0
        # At the polished front: out through the escape cone, else reflected.
        f = idx_live[going_front]
        leaves = rng.random(f.size) >= fresnel(dz[f], n, 1.0)
        out = np.zeros(N, bool)
        out[f[leaves]] = True
        deposit(out, x, y, front)
        alive[f[leaves]] = False
        dz[f[~leaves]] *= -1
        # At the foil: lost through its back, absorbed, or scattered again.
        b = idx_live[~going_front]
        r = rng.random(b.size)
        gone = r < P["foil_loss"] + P["foil_absorb"]
        lost = np.zeros(N, bool)
        lost[b[r < P["foil_loss"]]] = True
        deposit(lost, x, y, leak)
        alive[b[gone]] = False
        again = b[~gone]
        dx[again], dy[again], dz[again] = lambertian(rng, again.size)
    return front.reshape(H, W, 3), top, bottom, leak.reshape(H, W, 3)


def simulate(P):
    rng = np.random.default_rng(P["seed"])
    ppd = P["ppd"]
    S = ppd * BIN  # screen pixels per cell
    # The dock's glass, in cells.
    x0, y0 = -40.0, fake.DOCK_TOP
    W, H = int((1000 - x0) / BIN), int(round(fake.DOCK_H / BIN))
    grid = (x0, y0, H, W)
    xs = x0 + (np.arange(W) + 0.5) * BIN
    ys = y0 + (np.arange(H) + 0.5) * BIN

    # The wallpaper as light (linear), sampled at the cells and over the whole screen.
    wall_img = Image.open(P["wallpaper"]).convert("RGB")
    wall_screen = srgb_to_linear(np.asarray(wall_img.resize((round(960 * ppd), round(540 * ppd)), Image.LANCZOS), float) / 255)
    wall_cells_img = np.asarray(wall_img.resize((round(960 / BIN), round(540 / BIN)), Image.LANCZOS), float) / 255
    wall_cells_full = srgb_to_linear(wall_cells_img)  # 1920 x 1080 cells for the 960 x 540 dp screen

    def wall_at(full):
        """The full-screen cell image cut to the dock grid (black beyond the screen)."""
        out = np.zeros((H, W, 3))
        c0 = int(round(-x0 / BIN))
        r0 = int(round(y0 / BIN))
        out[:, c0:c0 + full.shape[1]] = full[r0:r0 + H, : W - c0]
        return out

    # The hot light: a rounded rectangle under the selected tile.
    tx, ty, tw, th = fake.tile_rect(P["selected"])
    cx, cy = tx + tw / 2, ty + th / 2
    lw, lh, lr = tw * P["light_scale"], th * P["light_scale"], fake.RADIUS * P["light_scale"]
    colour = blackbody_rgb(P["light_temp"]) * P["light_radiance"]

    def light_mask(xv, yv):
        dxv = np.maximum(np.abs(xv - cx) - (lw / 2 - lr), 0)
        dyv = np.maximum(np.abs(yv - cy) - (lh / 2 - lr), 0)
        return np.clip(lr + 0.5 * BIN - np.sqrt(dxv * dxv + dyv * dyv), 0, BIN) / BIN

    mask = light_mask(xs[None, :], ys[:, None])

    # Light lighting the wallpaper's surface (the hot light's back), over the
    # whole screen in cells: the bleed, part of the glow.
    sx = (np.arange(round(960 / BIN)) + 0.5) * BIN
    sy = (np.arange(round(540 / BIN)) + 0.5) * BIN
    screen_mask = light_mask(sx[None, :], sy[:, None])
    k_wall = irradiance_kernel(P["wall_gap"] - P["light_gap"], BIN)
    lit = fft_convolve(screen_mask, k_wall)[..., None] * colour  # irradiance on the wall
    bleed_full = lit * P["wall_albedo"] * wall_cells_full / np.pi  # radiance the wall gives back

    # What reaches the foil from behind, as radiance patterns and irradiance.
    k_far, k_near = irradiance_kernel(P["wall_gap"], BIN), irradiance_kernel(P["light_gap"], BIN)
    tau, wide = P["foil_transmit"], P["foil_wide"]
    cone = np.tan(np.radians(P["foil_cone"]))
    near_cone = gaussian_kernel(P["light_gap"] * cone, BIN)
    far_cone = gaussian_kernel(P["wall_gap"] * cone, BIN)

    smooth = gaussian_kernel(P["smooth"], BIN)
    rows = max(1, int(round(P["edge_width"] / BIN)))

    def through_glass(wall, light):
        """The band as seen through the glass, lit from behind by a wall
        (radiance per cell) and, scaled by light, the hot light; also the
        light leaving the edges and leaking out of the foil's back."""
        seen_mask = fft_convolve(mask, near_cone)
        narrow = fft_convolve(wall, far_cone) * (1 - seen_mask[..., None]) + light * seen_mask[..., None] * colour
        narrow *= tau * (1 - wide)
        near = fft_convolve(mask, k_near)[..., None]
        irr = fft_convolve(wall, k_far) * (1 - near) + light * near * colour
        front, top, bottom, leak = trace(irr * tau * wide * BIN * BIN, grid, P, rng)
        haze = fft_convolve(front, smooth) / (BIN * BIN) / np.pi
        edges = np.zeros_like(narrow)
        edges[:rows] += (top * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        edges[-rows:] += (bottom * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        return narrow + haze + edges, top, bottom, leak

    # The wallpaper's surface, for light falling on it: brighter where the
    # picture is brighter, a little tinted by it.
    lum = wall_cells_img @ [0.2126, 0.7152, 0.0722]
    tint = wall_cells_full / np.maximum(wall_cells_full @ [0.2126, 0.7152, 0.0722], 1e-4)[..., None]
    albedo = (P["wall_albedo_dark"] + (1 - P["wall_albedo_dark"]) * lum)[..., None] * (0.7 + 0.3 * np.clip(tint, 0, 3))
    albedo *= P["wall_albedo"]

    def embed(band):
        """A dock-grid image placed in the full-screen cell image (zero elsewhere)."""
        full = np.zeros(wall_cells_full.shape)
        c0, r0 = int(round(-x0 / BIN)), int(round(y0 / BIN))
        full[r0:r0 + H] = band[:, c0:c0 + full.shape[1]]
        return full

    out = {"glass": (through_glass(wall_at(wall_cells_full), 0.0)[0], wall_cells_full)}
    # The glow, first straight from the hot light; then the wallpaper it
    # lights: by the light's back, by light leaking out through the foil, and
    # by light leaving the cut edges toward it; seen around the glass and
    # through it.
    band, top, bottom, leak = through_glass(np.zeros((H, W, 3)), 1.0)
    k_back = irradiance_kernel(P["wall_gap"], BIN)
    leak_full = embed(leak / (BIN * BIN) / np.pi)
    edge_full = np.zeros_like(leak_full)
    r0 = int(round(y0 / BIN))
    c0 = int(round(-x0 / BIN))
    edge_full[r0] += top[c0:c0 + edge_full.shape[1]] * 0.5 / BIN / np.pi
    edge_full[r0 + H - 1] += bottom[c0:c0 + edge_full.shape[1]] * 0.5 / BIN / np.pi
    falling = lit + fft_convolve(leak_full + edge_full, k_back)
    bleed_full = falling * albedo / np.pi
    band_bleed = through_glass(wall_at(bleed_full), 0.0)[0]
    out["glow"] = (band + band_bleed, bleed_full)
    return out, grid


def compose(P, sim, grid):
    """The home screen: wallpaper, the glass dock (as light through look), tiles."""
    ppd = P["ppd"]
    x0, y0, H, W = grid
    Wp, Hp = round(960 * ppd), round(540 * ppd)
    up = lambda a: np.asarray(Image.fromarray(a.astype(np.float32)).resize((round(a.shape[1] * ppd * BIN), round(a.shape[0] * ppd * BIN)), Image.BILINEAR))

    def to_screen(cells_band, cells_full):
        """A dock-grid image and a full-screen cell image to one screen-sized linear image."""
        full = np.stack([np.asarray(Image.fromarray(cells_full[..., c].astype(np.float32)).resize((Wp, Hp), Image.BILINEAR)) for c in range(3)], -1)
        band = np.stack([up(cells_band[..., c]) for c in range(3)], -1)
        px0, py0 = round(-x0 * ppd), round(y0 * ppd)
        full[py0:py0 + band.shape[0], :] = band[:, px0:px0 + Wp][: Hp - py0]
        return full

    glass_band, wall_full = sim["glass"]
    glow_band, bleed_full = sim["glow"]
    screen = linear_to_srgb(to_screen(glass_band, wall_full))
    glow = look.tone(to_screen(glow_band, bleed_full), P["exposure"])
    image = np.clip(screen + glow, 0, 1)
    glow_light = to_screen(glow_band, bleed_full)
    near = np.stack([np.asarray(Image.fromarray(glow_light[..., c].astype(np.float32)).resize((Wp // 4, Hp // 4), Image.BILINEAR).resize((Wp, Hp), Image.BILINEAR)) for c in range(3)], -1)
    rim_light = np.zeros_like(image)
    tiles = [Image.open(f"{P['tiles']}/tile{i}.png") for i in range(6)]
    for i, tile in enumerate(tiles):
        x, y, w, h = fake.tile_rect(i, lifted=i == P["selected"])
        px, py, pw, ph = round(x * ppd), round(y * ppd), round(w * ppd), round(h * ppd)
        face = np.asarray(tile.convert("RGB").resize((pw, ph), Image.LANCZOS), float) / 255
        r = fake.RADIUS * (fake.LIFT if i == P["selected"] else 1) * ppd
        a = fake.rounded_mask(pw, ph, r)[..., None]
        image[py:py + ph, px:px + pw] = image[py:py + ph, px:px + pw] * (1 - a) + face * a
        # The tile's rounded edge, about a dp wide, lit by the glass glowing behind it.
        inner = fake.rounded_mask(pw - 2 * ppd, ph - 2 * ppd, max(r - ppd, 0))
        ring = a[..., 0].copy()
        ring[round(ppd):round(ppd) + inner.shape[0], round(ppd):round(ppd) + inner.shape[1]] -= inner
        rim_light[py:py + ph, px:px + pw] += np.clip(ring, 0, 1)[..., None] * near[py:py + ph, px:px + pw] * P["tile_rim"]
    return np.clip(image + look.tone(rim_light, P["exposure"]), 0, 1)


if __name__ == "__main__":
    P = {**DEFAULTS, **json.load(open(sys.argv[1]))}
    prefix = sys.argv[2]
    sim, grid = simulate(P)
    np.save(prefix + "-glow.npy", sim["glow"][0])
    fake.save(compose(P, sim, grid), prefix + ".png")
