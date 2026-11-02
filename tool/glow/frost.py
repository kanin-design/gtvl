"""The dock as a slab of cut glass with a frosted foil on its back, lit from
behind by a hot light under the app in focus and by the wallpaper further
back: a Monte Carlo light-transport simulation of that one object, with the
home screen put together around it.

Light is traced as it physically goes:
- the frosted back is a rough dielectric interface (GGX microfacets, after
  Walter et al. 2007, sampled by their visible normals, after Heitz 2018):
  light from behind refracts through it with a spread, and what refracts
  steeply enough is trapped inside the glass by total internal reflection;
- the polished front reflects and refracts by Fresnel's equations, totally
  beyond the critical angle;
- trapped light travels along the slab, meeting the frosted back again (where
  a little leaks out at every bounce) and the cut top and bottom edges, whose
  small polished bevels (arrises) let it out toward the viewer, lighting the
  edges up;
- light leaving the back, light the frosting reflects and the hot light's own
  back fall on the wallpaper's surface, which glows around the dock and,
  softened by the frosting, behind it.

The camera looks straight at the screen; the radiance toward it is estimated
from the light leaving within a narrow cone about the view direction. The
wallpaper seen through the frosting is the wallpaper convolved with the
slab's response to a point of light behind it, traced the same way.

  python3 frost.py params.json out_prefix
"""

import json
import sys

import numpy as np
from PIL import Image

import fake
import slab
from slab import BIN, blackbody_rgb, fft_convolve, fresnel, gaussian_kernel, srgb_to_linear

LUMA = np.array([0.2126, 0.7152, 0.0722])
SQ = 1 / np.sqrt(2)

DEFAULTS = {
    "wallpaper": "",
    "tiles": "",
    "selected": 1,
    "ppd": 2.0,
    # The glass: thickness, index, the frosting's roughness (GGX alpha), the
    # arrises' size (each bevel's leg, dp), and its faint milkiness (mean free
    # path in dp; 0 for none) with its forward bias.
    "thickness": 5.0,
    "ior": 1.5,
    "frost": 0.5,
    "arris": 0.8,
    "glass_mfp": 0.0,
    "glass_g": 0.0,
    # Distances behind the glass's back (dp).
    "light_gap": 40.0,
    "wall_gap": 80.0,
    # The hot light: shape ("pad", "tube" or "disc"), size against the tile,
    # the tube's height, softness of its edges (dp), temperature, radiance,
    # and how brightly its back glows against its front.
    "light_shape": "pad",
    "light_scale": 1.2,
    "light_tube": 8.0,
    "light_soft": 4.0,
    "light_temp": 2300.0,
    "light_radiance": 2.0,
    "light_back": 1.0,
    # The wallpaper's surface: reflectance at its darkest and brightest.
    "wall_albedo": 0.5,
    "wall_albedo_dark": 0.3,
    # The camera's estimate: half-angle of the cone about the view direction.
    "view_cone": 25.0,
    "tile_rim": 0.0,
    "smooth": 0.75,
    "rays": 2_000_000,
    "psf_rays": 3_000_000,
    "exposure": 3.0,
    "seed": 1,
}


def ggx_g1(cos_t, alpha):
    """Smith's masking for GGX, for a direction at cos_t to the macro normal."""
    c2 = np.clip(cos_t * cos_t, 1e-12, 1.0)
    lam = 0.5 * (-1 + np.sqrt(1 + alpha * alpha * (1 - c2) / c2))
    return 1 / (1 + lam)


def vndf(wx, wy, wz, alpha, rng):
    """A microfacet normal seen from (wx, wy, wz) (local frame, wz > 0),
    sampled from GGX's distribution of visible normals."""
    vx, vy, vz = alpha * wx, alpha * wy, wz
    inv = 1 / np.sqrt(vx * vx + vy * vy + vz * vz)
    vx, vy, vz = vx * inv, vy * inv, vz * inv
    lensq = vx * vx + vy * vy
    has = lensq > 1e-14
    il = np.where(has, 1 / np.sqrt(np.where(has, lensq, 1)), 0)
    t1x, t1y = np.where(has, -vy * il, 1.0), np.where(has, vx * il, 0.0)
    t2x, t2y, t2z = -vz * t1y, vz * t1x, vx * t1y - vy * t1x
    n = wx.size
    r, phi = np.sqrt(rng.random(n)), 2 * np.pi * rng.random(n)
    p1, p2 = r * np.cos(phi), r * np.sin(phi)
    s = 0.5 * (1 + vz)
    p2 = (1 - s) * np.sqrt(np.clip(1 - p1 * p1, 0, 1)) + s * p2
    p3 = np.sqrt(np.clip(1 - p1 * p1 - p2 * p2, 0, 1))
    nx, ny, nz = p1 * t1x + p2 * t2x + p3 * vx, p1 * t1y + p2 * t2y + p3 * vy, p2 * t2z + p3 * vz
    mx, my, mz = alpha * nx, alpha * ny, np.maximum(nz, 1e-7)
    inv = 1 / np.sqrt(mx * mx + my * my + mz * mz)
    return mx * inv, my * inv, mz * inv


def rough(dx, dy, dz, alpha, n_i, n_t, rng, tries=12):
    """Rays (travelling d) meeting a rough interface parallel to z = const,
    from a medium of index n_i into one of n_t. Fresnel picks reflection or
    refraction at the sampled microfacet; a direction masked by the
    microsurface is sampled again, so no light is lost there. Returns the new
    directions, whether each crossed, and whether each was resolved."""
    k = dx.size
    sgn = np.where(dz < 0, 1.0, -1.0)  # the incident side, as +z in the local frame
    wx, wy, wz = -dx, -dy, -dz * sgn
    ox, oy, oz = np.zeros(k), np.zeros(k), np.zeros(k)
    crossed, done = np.zeros(k, bool), np.zeros(k, bool)
    alpha = np.broadcast_to(alpha, (k,))
    eta = n_i / n_t
    for _ in range(tries):
        j = np.nonzero(~done)[0]
        if j.size == 0:
            break
        a = alpha[j]
        mx, my, mz = vndf(wx[j], wy[j], wz[j], a, rng)
        ci = np.clip(wx[j] * mx + wy[j] * my + wz[j] * mz, 1e-9, 1)
        refl = rng.random(j.size) < fresnel(ci, n_i, n_t)
        ct = np.sqrt(np.clip(1 - eta * eta * (1 - ci * ci), 0, 1))
        f = eta * ci - ct
        cx = np.where(refl, 2 * ci * mx - wx[j], -eta * wx[j] + f * mx)
        cy = np.where(refl, 2 * ci * my - wy[j], -eta * wy[j] + f * my)
        cz = np.where(refl, 2 * ci * mz - wz[j], -eta * wz[j] + f * mz)
        valid = np.where(refl, cz > 0, cz < 0)
        ok = valid & (rng.random(j.size) < ggx_g1(np.abs(cz), a))
        acc = j[ok]
        ox[acc], oy[acc], oz[acc] = cx[ok], cy[ok], cz[ok]
        crossed[acc] = ~refl[ok]
        done[acc] = True
    return ox, oy, oz * sgn, crossed, done


def smooth(dx, dy, dz, nx, ny, nz, n_i, n_t, rng):
    """Rays meeting a polished interface whose normal n points into the far
    medium: Fresnel reflection or Snell refraction."""
    ci = np.clip(dx * nx + dy * ny + dz * nz, 1e-9, 1)
    refl = rng.random(dx.size) < fresnel(ci, n_i, n_t)
    eta = n_i / n_t
    f = np.sqrt(np.clip(1 - eta * eta * (1 - ci * ci), 0, 1)) - eta * ci
    ox = np.where(refl, dx - 2 * ci * nx, eta * dx + f * nx)
    oy = np.where(refl, dy - 2 * ci * ny, eta * dy + f * ny)
    oz = np.where(refl, dz - 2 * ci * nz, eta * dz + f * nz)
    return ox, oy, oz, ~refl


def scatter_hg(rng, dx, dy, dz, g):
    """New directions after scattering in the glass (Henyey-Greenstein)."""
    from guide import scatter

    return scatter(rng, dx, dy, dz, g)


class Slab:
    """The glass in cross-section (y down the screen, z toward the viewer;
    back at z = 0, front at z = t), as outward-facing planes (ny, nz, h): the
    inside is where ny y + nz z <= h. The first is the frosted back. Without
    a band the slab is infinite in y (for its point spread function)."""

    def __init__(self, P, band=None):
        t, k = P["thickness"], P["arris"]
        self.t = t
        planes = [(0.0, -1.0, 0.0), (0.0, 1.0, t)]
        if band:
            top, bottom = band
            planes += [
                (-1.0, 0.0, -top),
                (1.0, 0.0, bottom),
                (-SQ, SQ, SQ * (t - k - top)),
                (-SQ, -SQ, SQ * (-top - k)),
                (SQ, SQ, SQ * (bottom + t - k)),
                (SQ, -SQ, SQ * (bottom - k)),
            ]
        self.planes = planes


def trace(slab_, x, y, z, dx, dy, dz, w, P, rng, on_exit, x_range, alpha_at=None):
    """Traces rays inside the glass until they leave, calling
    on_exit(x, y, z, dx, dy, dz, w) for each batch leaving it. alpha_at(x, y)
    gives the back's roughness where it varies (else P["frost"])."""
    n = P["ior"]
    mfp = P["glass_mfp"]
    planes = slab_.planes
    alive = np.ones(x.size, bool)
    lo, hi = x_range
    for _ in range(6000):
        i = np.nonzero(alive)[0]
        if i.size == 0:
            break
        Y, Z, DY, DZ = y[i], z[i], dy[i], dz[i]
        dist = np.full((len(planes) + 1, i.size), np.inf)
        for p, (ny, nz, h) in enumerate(planes):
            dn = ny * DY + nz * DZ
            with np.errstate(divide="ignore", invalid="ignore"):
                d = np.where(dn > 1e-12, (h - (ny * Y + nz * Z)) / dn, np.inf)
            dist[p] = np.maximum(d, 0)
        if mfp > 0:
            dist[-1] = -mfp * np.log(rng.random(i.size))
        hit = dist.argmin(0)
        s = dist[hit, np.arange(i.size)]
        x[i] += dx[i] * s
        y[i] += DY * s
        z[i] += DZ * s
        exits = []
        # The frosted back.
        b = i[hit == 0]
        if b.size:
            alpha = P["frost"] if alpha_at is None else alpha_at(x[b], y[b])
            ox, oy, oz, crossed, ok = rough(dx[b], dy[b], dz[b], alpha, n, 1.0, rng)
            alive[b[~ok]] = False
            stay = ok & ~crossed
            dx[b[stay]], dy[b[stay]], dz[b[stay]] = ox[stay], oy[stay], oz[stay]
            go = ok & crossed
            exits.append((b[go], ox[go], oy[go], oz[go]))
        # The polished faces, edges and arrises.
        for p in range(1, len(planes)):
            f = i[hit == p]
            if f.size == 0:
                continue
            ny, nz, _ = planes[p]
            ox, oy, oz, out = smooth(dx[f], dy[f], dz[f], 0.0, ny, nz, n, 1.0, rng)
            stay = ~out
            dx[f[stay]], dy[f[stay]], dz[f[stay]] = ox[stay], oy[stay], oz[stay]
            exits.append((f[out], ox[out], oy[out], oz[out]))
        # The glass's milkiness.
        sc = i[hit == len(planes)]
        if sc.size:
            dx[sc], dy[sc], dz[sc] = scatter_hg(rng, dx[sc], dy[sc], dz[sc], P["glass_g"])
        for idx, ox, oy, oz in exits:
            if idx.size:
                on_exit(x[idx], y[idx], z[idx], ox, oy, oz, w[idx])
                alive[idx] = False
        alive[i[(x[i] < lo) | (x[i] > hi)]] = False


def cosine_dirs(rng, k):
    u, phi = rng.random(k), 2 * np.pi * rng.random(k)
    return np.sqrt(1 - u) * np.cos(phi), np.sqrt(1 - u) * np.sin(phi), np.sqrt(u)


def enter(slab_, x, y, dx, dy, dz, w, gap, P, rng, on_exit, x_range, rows=None):
    """Light leaving a plane gap behind the glass (travelling +z) and meeting
    its frosted back: refracted in (and traced), or reflected back."""
    s = gap / dz
    x, y = x + dx * s, y + dy * s
    if rows is not None:
        k = P["arris"]
        on = (y > rows[0] + k) & (y < rows[1] - k)
        x, y, dx, dy, dz, w = x[on], y[on], dx[on], dy[on], dz[on], w[on]
    ox, oy, oz, crossed, ok = rough(dx, dy, dz, P["frost"], 1.0, P["ior"], rng)
    back = ok & ~crossed
    on_exit(x[back], y[back], np.zeros(back.sum()), ox[back], oy[back], oz[back], w[back])
    go = ok & crossed
    z = np.zeros(go.sum())
    trace(slab_, x[go], y[go], z, ox[go], oy[go], oz[go], w[go], P, rng, on_exit, x_range)


def point_spread(P, rng):
    """The radiance seen through the glass from one cell of unit radiance on
    the wallpaper's plane, for an infinite slab: a kernel to convolve the
    wallpaper with (rows, cols odd, centred)."""
    rx, ry = int(160 / BIN), int(80 / BIN)
    kernel = np.zeros((2 * ry + 1, 2 * rx + 1))
    N = int(P["psf_rays"])
    cone = np.cos(np.radians(P["view_cone"]))
    scale = 1 / (BIN * BIN * np.pi * np.sin(np.radians(P["view_cone"])) ** 2)

    def on_exit(x, y, z, dx, dy, dz, w):
        seen = dz > cone
        jx = np.round(x[seen] / BIN).astype(int) + rx
        jy = np.round(y[seen] / BIN).astype(int) + ry
        ok = (jx >= 0) & (jx <= 2 * rx) & (jy >= 0) & (jy <= 2 * ry)
        np.add.at(kernel, (jy[ok], jx[ok]), w[seen][ok, 0] * scale)

    x = (rng.random(N) - 0.5) * BIN
    y = (rng.random(N) - 0.5) * BIN
    dx, dy, dz = cosine_dirs(rng, N)
    w = np.full((N, 1), np.pi * BIN * BIN / N)
    enter(Slab(P), x, y, dx, dy, dz, w, P["wall_gap"], P, rng, on_exit, (-200, 200))
    return kernel


def simulate(P):
    rng = np.random.default_rng(P["seed"])
    x0, y0 = -40.0, fake.DOCK_TOP
    W, H = int((1000 - x0) / BIN), int(round(fake.DOCK_H / BIN))
    grid = (x0, y0, H, W)
    rows = (y0, y0 + H * BIN)
    sw, sh = round(960 / BIN), round(540 / BIN)
    r0, c0 = int(round(y0 / BIN)), int(round(-x0 / BIN))

    wall_img = Image.open(P["wallpaper"]).convert("RGB")
    wall_srgb = np.asarray(wall_img.resize((sw, sh), Image.LANCZOS), float) / 255
    wall_full = srgb_to_linear(wall_srgb)

    def band(full):
        out = np.zeros((H, W, full.shape[2]))
        out[:, c0:c0 + sw] = full[r0:r0 + H, : W - c0]
        return out

    # The hot light, under the selected tile.
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
    sx = (np.arange(sw) + 0.5) * BIN
    sy = (np.arange(sh) + 0.5) * BIN
    ddx = np.maximum(np.abs(sx[None, :] - cx) - (lw / 2 - lr), 0)
    ddy = np.maximum(np.abs(sy[:, None] - cy) - (lh / 2 - lr), 0)
    mask_full = np.clip(lr + 0.5 * BIN - np.sqrt(ddx * ddx + ddy * ddy), 0, BIN) / BIN
    if P["light_soft"] > 0:
        mask_full = fft_convolve(mask_full, gaussian_kernel(P["light_soft"], BIN))

    # What the camera sees of the light, and what falls on the wallpaper.
    image = np.zeros((H * W, 3))
    wall_flux = np.zeros((sh * sw, 3))
    cone = np.cos(np.radians(P["view_cone"]))
    radiance = 1 / (BIN * BIN * np.pi * np.sin(np.radians(P["view_cone"])) ** 2)
    gap = P["wall_gap"]

    def on_exit(x, y, z, dx, dy, dz, w):
        seen = dz > cone
        jx = np.clip(((x[seen] - x0) / BIN).astype(int), 0, W - 1)
        jy = np.clip(((y[seen] - y0) / BIN).astype(int), 0, H - 1)
        for c in range(3):
            image[:, c] += np.bincount(jy * W + jx, w[seen, c] * radiance, minlength=H * W)
        down = dz < 0
        sd = (z[down] + gap) / -dz[down]
        lx, ly = x[down] + dx[down] * sd, y[down] + dy[down] * sd
        jx, jy = (lx / BIN).astype(int), (ly / BIN).astype(int)
        ok = (jx >= 0) & (jx < sw) & (jy >= 0) & (jy < sh)
        for c in range(3):
            wall_flux[:, c] += np.bincount(jy[ok] * sw + jx[ok], w[down][ok, c], minlength=sh * sw)

    N = int(P["rays"])
    prob = mask_full.ravel() / mask_full.sum()
    cells = np.minimum(np.searchsorted(np.cumsum(prob), rng.random(N)), prob.size - 1)
    iy, ix = np.divmod(cells, sw)
    lx, ly = (ix + rng.random(N)) * BIN, (iy + rng.random(N)) * BIN
    dx, dy, dz = cosine_dirs(rng, N)
    w = np.tile(np.pi * colour * mask_full.sum() * BIN * BIN / N, (N, 1))
    enter(Slab(P, rows), lx, ly, dx, dy, dz, w, P["light_gap"], P, rng, on_exit, (x0 - 300, x0 + W * BIN + 300), rows)

    smooth_k = gaussian_kernel(P["smooth"], BIN)
    glow_band = fft_convolve(image.reshape(H, W, 3), smooth_k)
    # The wallpaper: lit by the glass's light and by the hot light's back.
    import guide

    falling = fft_convolve(wall_flux.reshape(sh, sw, 3), smooth_k) / (BIN * BIN)
    falling += P["light_back"] * fft_convolve(mask_full, guide.kernel(gap - P["light_gap"]))[..., None] * colour
    lum = wall_srgb @ LUMA
    tint = wall_full / np.maximum(wall_full @ LUMA, 1e-4)[..., None]
    albedo = P["wall_albedo"] * (P["wall_albedo_dark"] + (1 - P["wall_albedo_dark"]) * lum)[..., None]
    albedo = albedo * (0.7 + 0.3 * np.clip(tint, 0, 3))
    bleed = falling * albedo / np.pi
    # Seen through the frosting.
    psf = point_spread(P, rng)
    glass_band = band(fft_convolve(wall_full, psf))
    glow_band += band(fft_convolve(bleed, psf))
    # Any of the hot light reaching past the glass, seen directly.
    outside = np.ones((sh, 1))
    outside[r0:r0 + H] = 0
    glow_full = bleed + mask_full[..., None] * colour * outside[..., None]
    return {"glass": (glass_band, wall_full), "glow": (glow_band, glow_full)}, grid


if __name__ == "__main__":
    P = {**DEFAULTS, **json.load(open(sys.argv[1]))}
    sim, grid = simulate(P)
    np.save(sys.argv[2] + "-glow.npy", sim["glow"][0])
    fake.save(slab.compose(P, sim, grid), sys.argv[2] + ".png")
