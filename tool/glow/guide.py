"""The dock as a light guide: a slab of cut glass, polished on both faces and
on its cut top and bottom edges, very faintly milky, with a diffusing foil
behind it across a thin air gap; behind the foil, a hot light under the app in
focus; further back, the wallpaper. A light-transport simulation of that one
object, and the home screen put together around it (as slab.py, whose
laminated foil kills trapped light at every bounce).

The foil softens what lies behind it: most of the light through it a little
(a narrow cone, so the wallpaper blurs by an amount that grows with its
distance, and the nearer hot light shows almost sharp), the rest in all
directions. That is what the eye sees through the clear glass, worked out
exactly as blurs. The glass, polished on both faces, would pass all of it
straight through; but it is faintly milky, so a few percent scatters inside
it, and most of that scatters beyond the escape cones and is trapped by total
internal reflection at both faces. Trapped light travels along the slab until
it scatters again (sometimes out through the front, a soft glow in the glass),
or meets a cut edge: polished, it reflects what comes at a glancing angle and
lets out the rest, lighting the edge far along the dock. Light leaving the
back, the hot light's own back, light the foil sends back and light leaving
the edges fall on the wallpaper's surface, which glows around and through
the dock.

  python3 guide.py params.json out_prefix
"""

import json
import sys

import numpy as np
from PIL import Image

import fake
import slab
from slab import BIN, blackbody_rgb, fft_convolve, fresnel, gaussian_kernel, srgb_to_linear

LUMA = np.array([0.2126, 0.7152, 0.0722])

DEFAULTS = {
    "wallpaper": "",
    "tiles": "",
    "selected": 1,
    "ppd": 2.0,
    # The glass: thickness and index; how far light goes in it, on average,
    # before scattering (dp: very faintly milky), the scattering's forward
    # bias (Henyey-Greenstein g) and absorption per dp.
    "thickness": 5.0,
    "ior": 1.5,
    "glass_mfp": 150.0,
    "glass_g": 0.0,
    "glass_absorb": 0.0005,
    # The cut edges: of light leaving them, the share their finish sends to
    # the viewer and the share toward the wallpaper; the line's width (dp).
    "edge_scatter": 0.3,
    "edge_back": 0.4,
    "edge_width": 1.0,
    # The foil: share let through, the wide (all-directions) part of that,
    # the narrow cone's spread (degrees, in air), share sent back.
    "foil_transmit": 0.8,
    "foil_wide": 0.35,
    "foil_cone": 12.0,
    "foil_reflect": 0.15,
    # Distances (dp): foil to hot light, foil to wallpaper.
    "light_gap": 24.0,
    "wall_gap": 60.0,
    # The light pressed against the glass's back through a diffusing contact
    # ("inject"), or standing behind the foil ("behind"). In contact: the
    # share of light coming back to the contact that it scatters back into
    # the glass (the rest it absorbs); its back's brightness against its
    # front; the air gap from the glass's back to the foil; the foil's
    # reflectance from the glass's side.
    "light_mode": "inject",
    "contact_return": 0.5,
    "light_back": 0.5,
    "foil_gap": 6.0,
    "foil_front_reflect": 0.3,
    # The hot light: size against the tile's, the softness of its edges (dp;
    # a glowing source fades out rather than stopping), temperature, radiance.
    "light_scale": 1.15,
    "light_soft": 0.0,
    "light_temp": 2300.0,
    "light_radiance": 1.6,
    # The wallpaper's surface: reflectance at its darkest and brightest.
    "wall_albedo": 0.5,
    "wall_albedo_dark": 0.3,
    "tile_rim": 0.25,
    "smooth": 0.75,
    "rays": 3_000_000,
    "exposure": 3.0,
    "seed": 1,
}


def kernel(distance):
    """slab.irradiance_kernel cut at eight times the distance (sums to ~pi)."""
    r = int(np.ceil(distance * 8 / BIN))
    y, x = np.mgrid[-r:r + 1, -r:r + 1] * BIN
    d2 = distance * distance
    return d2 / (d2 + x * x + y * y) ** 2 * BIN * BIN


def scatter(rng, dx, dy, dz, g):
    """New directions after scattering: isotropic, or Henyey-Greenstein about the old."""
    k = dx.size
    if abs(g) < 1e-3:
        cos_t = 1 - 2 * rng.random(k)
    else:
        s = (1 - g * g) / (1 - g + 2 * g * rng.random(k))
        cos_t = (1 + g * g - s * s) / (2 * g)
    sin_t = np.sqrt(np.clip(1 - cos_t * cos_t, 0, 1))
    phi = 2 * np.pi * rng.random(k)
    if abs(g) < 1e-3:
        return sin_t * np.cos(phi), sin_t * np.sin(phi), cos_t
    # Rotate (sin cos phi, sin sin phi, cos) from +z to the old direction.
    ux, uy, uz = dx, dy, dz
    a = np.where(np.abs(uz) < 0.999, 1.0, 0.0)
    tx, ty, tz = a * -uy, a * ux + (1 - a), np.zeros(k)  # a vector not parallel to u
    nx, ny, nz = uy * tz - uz * ty, uz * tx - ux * tz, ux * ty - uy * tx
    norm = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / norm, ny / norm, nz / norm
    bx, by, bz = uy * nz - uz * ny, uz * nx - ux * nz, ux * ny - uy * nx
    c, s1, s2 = cos_t, sin_t * np.cos(phi), sin_t * np.sin(phi)
    return c * ux + s1 * nx + s2 * bx, c * uy + s1 * ny + s2 * by, c * uz + s1 * nz + s2 * bz


def trace(source, grid, P, rng):
    """Light scattered inside the glass, traced until it leaves.

    source: H x W x 3 flux per cell that scatters inside the glass (where it
    first scatters). Returns flux leaving the front per cell, the back per
    cell, and the top and bottom edges per column.
    """
    x0, y0, H, W = grid
    t, n = P["thickness"], P["ior"]
    cos_c = np.sqrt(1 - 1 / n**2)  # rays steeper than this toward a face can leave through it
    y_top, y_bottom = y0, y0 + H * BIN
    lum = source @ LUMA
    total = lum.sum()
    front, back = np.zeros((H * W, 3)), np.zeros((H * W, 3))
    top, bottom = np.zeros((W, 3)), np.zeros((W, 3))
    if total <= 0:
        return front.reshape(H, W, 3), back.reshape(H, W, 3), top, bottom
    N = int(P["rays"])
    cells = np.minimum(np.searchsorted(np.cumsum(lum.ravel()) / total, rng.random(N)), H * W - 1)
    iy, ix = np.divmod(cells, W)
    x = x0 + (ix + rng.random(N)) * BIN
    y = y0 + (iy + rng.random(N)) * BIN
    z = rng.random(N) * t
    weight = source.reshape(-1, 3)[cells] / np.maximum(lum.ravel()[cells, None], 1e-30) * (total / N)
    dx, dy, dz = scatter(rng, np.zeros(N), np.zeros(N), np.ones(N), P["glass_g"])
    alive = np.ones(N, bool)

    def tally(into, sel, px, py):
        jx = np.clip(((px - x0) / BIN).astype(int), 0, W - 1)
        jy = np.clip(((py - y0) / BIN).astype(int), 0, H - 1)
        for c in range(3):
            into[:, c] += np.bincount(jy * W + jx, weight[sel, c], minlength=H * W)

    def tally_edge(into, sel, px):
        jx = np.clip(((px - x0) / BIN).astype(int), 0, W - 1)
        for c in range(3):
            into[:, c] += np.bincount(jx, weight[sel, c], minlength=W)

    for _ in range(2000):
        i = np.nonzero(alive)[0]
        if i.size == 0:
            break
        ddx, ddy, ddz = dx[i], dy[i], dz[i]
        s_scat = -P["glass_mfp"] * np.log(rng.random(i.size))
        in_cone = np.abs(ddz) > cos_c
        with np.errstate(divide="ignore", invalid="ignore"):
            s_face = np.where(in_cone, np.where(ddz > 0, (t - z[i]) / ddz, -z[i] / ddz), np.inf)
            s_edge = np.where(ddy < 0, (y_top - y[i]) / ddy, np.where(ddy > 0, (y_bottom - y[i]) / ddy, np.inf))
        s_face = np.maximum(s_face, 0)
        s_edge = np.maximum(s_edge, 0)
        s = np.minimum(np.minimum(s_scat, s_face), s_edge)
        x[i] += ddx * s
        y[i] += ddy * s
        # Away from the escape cones, both faces reflect totally: fold the depth.
        zr = z[i] + ddz * s
        k = np.floor(zr / t)
        r = zr - k * t
        odd = (k % 2 != 0) & ~in_cone
        z[i] = np.where(in_cone, np.clip(zr, 0, t), np.where(odd, t - r, r))
        dz[i] = np.where(odd, -ddz, ddz)
        weight[i] *= np.exp(-P["glass_absorb"] * s)[:, None]
        face = in_cone & (s == s_face)
        edge = ~face & (s == s_edge)
        scat = ~face & ~edge
        # A face, inside its cone: out, or reflected.
        fi = i[face]
        leaves = rng.random(fi.size) >= fresnel(np.abs(dz[fi]), n, 1.0)
        out_front = fi[leaves & (dz[fi] > 0)]
        out_back = fi[leaves & (dz[fi] < 0)]
        tally(front, out_front, x[out_front], y[out_front])
        tally(back, out_back, x[out_back], y[out_back])
        alive[fi[leaves]] = False
        dz[fi[~leaves]] *= -1
        # A cut edge: out, or reflected (totally at glancing angles).
        ei = i[edge]
        leaves = rng.random(ei.size) >= fresnel(np.abs(dy[ei]), n, 1.0)
        out_top = ei[leaves & (dy[ei] < 0)]
        out_bottom = ei[leaves & (dy[ei] > 0)]
        tally_edge(top, out_top, x[out_top])
        tally_edge(bottom, out_bottom, x[out_bottom])
        alive[ei[leaves]] = False
        dy[ei[~leaves]] *= -1
        y[ei] = np.clip(y[ei], y_top + 1e-6, y_bottom - 1e-6)
        # Scattered again.
        si = i[scat]
        dx[si], dy[si], dz[si] = scatter(rng, dx[si], dy[si], dz[si], P["glass_g"])
        # Light too faint to matter, or leaving the dock sideways, stops.
        alive[i[(x[i] < x0 - 200) | (x[i] > x0 + W * BIN + 200)]] = False
    return front.reshape(H, W, 3), back.reshape(H, W, 3), top, bottom


def trace_contact(inject, contact, grid, P, rng):
    """Light let into the glass through the contact (inject: H x W x 3 flux per
    cell, spread as a Lambertian surface sends it up into the glass), traced
    through every reflection: totally reflected at both polished faces beyond
    the escape cones, scattered by the glass's faint milkiness, returned to
    the contact (contact: H x W, 0..1) where it is scattered back in or
    absorbed, and let out of the front, the back and the cut edges.
    Returns flux leaving the front and back per cell, and the top and bottom
    edges per column."""
    x0, y0, H, W = grid
    t, n = P["thickness"], P["ior"]
    y_top, y_bottom = y0, y0 + H * BIN
    lum = inject @ LUMA
    total = lum.sum()
    front, back = np.zeros((H * W, 3)), np.zeros((H * W, 3))
    top, bottom = np.zeros((W, 3)), np.zeros((W, 3))
    if total <= 0:
        return front.reshape(H, W, 3), back.reshape(H, W, 3), top, bottom
    N = int(P["rays"])
    cells = np.minimum(np.searchsorted(np.cumsum(lum.ravel()) / total, rng.random(N)), H * W - 1)
    iy, ix = np.divmod(cells, W)
    x = x0 + (ix + rng.random(N)) * BIN
    y = y0 + (iy + rng.random(N)) * BIN
    z = np.full(N, 1e-6)
    weight = inject.reshape(-1, 3)[cells] / np.maximum(lum.ravel()[cells, None], 1e-30) * (total / N)
    u = rng.random(N)
    phi = 2 * np.pi * rng.random(N)
    dx, dy, dz = np.sqrt(1 - u) * np.cos(phi), np.sqrt(1 - u) * np.sin(phi), np.sqrt(u)
    alive = np.ones(N, bool)
    flat = contact.ravel()

    def cell(px, py):
        jx = np.clip(((px - x0) / BIN).astype(int), 0, W - 1)
        jy = np.clip(((py - y0) / BIN).astype(int), 0, H - 1)
        return jy * W + jx, jx

    def tally(into, sel):
        k, _ = cell(x[sel], y[sel])
        for c in range(3):
            into[:, c] += np.bincount(k, weight[sel, c], minlength=H * W)

    def tally_edge(into, sel):
        _, jx = cell(x[sel], y[sel])
        for c in range(3):
            into[:, c] += np.bincount(jx, weight[sel, c], minlength=W)

    for _ in range(5000):
        i = np.nonzero(alive)[0]
        if i.size == 0:
            break
        ddx, ddy, ddz = dx[i], dy[i], dz[i]
        s_scat = -P["glass_mfp"] * np.log(rng.random(i.size))
        with np.errstate(divide="ignore", invalid="ignore"):
            s_face = np.where(ddz > 0, (t - z[i]) / ddz, np.where(ddz < 0, -z[i] / ddz, np.inf))
            s_edge = np.where(ddy < 0, (y_top - y[i]) / ddy, np.where(ddy > 0, (y_bottom - y[i]) / ddy, np.inf))
        s = np.minimum(np.minimum(s_scat, np.maximum(s_face, 0)), np.maximum(s_edge, 0))
        x[i] += ddx * s
        y[i] += ddy * s
        z[i] = np.clip(z[i] + ddz * s, 0, t)
        weight[i] *= np.exp(-P["glass_absorb"] * s)[:, None]
        face = s == np.maximum(s_face, 0)
        edge = ~face & (s == np.maximum(s_edge, 0))
        scat = ~face & ~edge
        # The faces: at the back, the contact takes it; elsewhere Fresnel
        # (total beyond the escape cones) decides between out and back in.
        fi = i[face]
        at_back = dz[fi] < 0
        k, _ = cell(x[fi], y[fi])
        touching = at_back & (rng.random(fi.size) < flat[k])
        tc = fi[touching]
        returned = rng.random(tc.size) < P["contact_return"]
        alive[tc[~returned]] = False
        rt = tc[returned]
        u = rng.random(rt.size)
        phi = 2 * np.pi * rng.random(rt.size)
        dx[rt], dy[rt], dz[rt] = np.sqrt(1 - u) * np.cos(phi), np.sqrt(1 - u) * np.sin(phi), np.sqrt(u)
        z[rt] = 1e-6
        fo = fi[~touching]
        leaves = rng.random(fo.size) >= fresnel(np.abs(dz[fo]), n, 1.0)
        out_front = fo[leaves & (dz[fo] > 0)]
        out_back = fo[leaves & (dz[fo] < 0)]
        tally(front, out_front)
        tally(back, out_back)
        alive[fo[leaves]] = False
        dz[fo[~leaves]] *= -1
        # The cut edges.
        ei = i[edge]
        leaves = rng.random(ei.size) >= fresnel(np.abs(dy[ei]), n, 1.0)
        tally_edge(top, ei[leaves & (dy[ei] < 0)])
        tally_edge(bottom, ei[leaves & (dy[ei] > 0)])
        alive[ei[leaves]] = False
        dy[ei[~leaves]] *= -1
        y[ei] = np.clip(y[ei], y_top + 1e-6, y_bottom - 1e-6)
        # The glass's milkiness.
        si = i[scat]
        dx[si], dy[si], dz[si] = scatter(rng, dx[si], dy[si], dz[si], P["glass_g"])
        # Gone far past the screen, or too faint to matter.
        far = (x[i] < x0 - 200) | (x[i] > x0 + W * BIN + 200) | (weight[i] @ LUMA < 1e-9 * total / N)
        alive[i[far]] = False
    return front.reshape(H, W, 3), back.reshape(H, W, 3), top, bottom


def simulate(P):
    rng = np.random.default_rng(P["seed"])
    x0, y0 = -40.0, fake.DOCK_TOP
    W, H = int((1000 - x0) / BIN), int(round(fake.DOCK_H / BIN))
    grid = (x0, y0, H, W)
    xs = x0 + (np.arange(W) + 0.5) * BIN
    ys = y0 + (np.arange(H) + 0.5) * BIN
    sw, sh = round(960 / BIN), round(540 / BIN)
    c0, r0 = int(round(-x0 / BIN)), int(round(y0 / BIN))

    wall_img = Image.open(P["wallpaper"]).convert("RGB")
    wall_srgb = np.asarray(wall_img.resize((sw, sh), Image.LANCZOS), float) / 255
    wall_full = srgb_to_linear(wall_srgb)

    def band(full):
        out = np.zeros((H, W, full.shape[2]))
        out[:, c0:c0 + sw] = full[r0:r0 + H, : W - c0]
        return out

    def embed(b):
        full = np.zeros((sh, sw, b.shape[2]))
        full[r0:r0 + H] = b[:, c0:c0 + sw]
        return full

    # The hot light, under the selected tile; a glowing one fades at its edges.
    tx, ty, tw, th = fake.tile_rect(P["selected"])
    cx, cy = tx + tw / 2, ty + th / 2
    lw, lh, lr = tw * P["light_scale"], th * P["light_scale"], fake.RADIUS * P["light_scale"]
    colour = blackbody_rgb(P["light_temp"]) * P["light_radiance"]

    def light_mask(xv, yv):
        ddx = np.maximum(np.abs(xv - cx) - (lw / 2 - lr), 0)
        ddy = np.maximum(np.abs(yv - cy) - (lh / 2 - lr), 0)
        m = np.clip(lr + 0.5 * BIN - np.sqrt(ddx * ddx + ddy * ddy), 0, BIN) / BIN
        if P["light_soft"] > 0:
            m = fft_convolve(m, gaussian_kernel(P["light_soft"], BIN))
        return m

    sx = (np.arange(sw) + 0.5) * BIN
    sy = (np.arange(sh) + 0.5) * BIN
    mask_full = light_mask(sx[None, :], sy[:, None])
    mask = band(mask_full[..., None])[..., 0]

    tau, wide, refl = P["foil_transmit"], P["foil_wide"], P["foil_reflect"]
    cone = np.tan(np.radians(P["foil_cone"]))
    T_glass = (1 - 0.04) ** 2
    t_eff = 1.15 * P["thickness"]
    p_scatter = 1 - np.exp(-t_eff / P["glass_mfp"])
    smooth = gaussian_kernel(P["smooth"], BIN)
    rows = max(1, int(round(P["edge_width"] / BIN)))

    def view(wall, light):
        """The band through the glass, lit from behind by a wall (radiance per
        cell, full screen) and, scaled by light, the hot light; with the light
        scattered in the glass traced. Returns the band and what leaves the
        glass's back and edges (for the wallpaper behind)."""
        wall_b = band(wall)
        near = fft_convolve(mask, kernel(P["light_gap"]))  # 0..pi: the hot light's share of the sky
        hot = light * near[..., None] * colour  # irradiance from the hot light
        sky = fft_convolve(wall_b, kernel(P["wall_gap"])) * (1 - near / np.pi)[..., None]
        seen = fft_convolve(mask, gaussian_kernel(P["light_gap"] * cone, BIN))[..., None]
        narrow = fft_convolve(wall_b, gaussian_kernel(P["wall_gap"] * cone, BIN)) * (1 - seen) + light * seen * colour
        foil = tau * ((1 - wide) * narrow + wide * (sky + hot) / np.pi)
        direct = foil * T_glass * (1 - p_scatter)
        source = tau * (sky + hot) * (1 - 0.04) * p_scatter * BIN * BIN
        front, back, top, bottom = trace(source, grid, P, rng)
        glow = fft_convolve(front, smooth) / (BIN * BIN) / np.pi
        edges = np.zeros_like(direct)
        edges[:rows] += (top * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        edges[-rows:] += (bottom * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        return direct + glow + edges, back, top, bottom, hot

    # The wallpaper's surface, for light falling on it.
    lum = wall_srgb @ LUMA
    tint = wall_full / np.maximum(wall_full @ LUMA, 1e-4)[..., None]
    albedo = P["wall_albedo"] * (P["wall_albedo_dark"] + (1 - P["wall_albedo_dark"]) * lum)[..., None]
    albedo = albedo * (0.7 + 0.3 * np.clip(tint, 0, 3))

    glass_band = view(wall_full, 0.0)[0]
    gap = P["wall_gap"]
    if P["light_mode"] == "inject":
        # The light in contact: its front's light all goes into the glass;
        # traced from there. Its back, and light leaving the glass's back,
        # light the foil, which glows back through the glass (where the light
        # doesn't hide it) and passes some on to the wallpaper.
        inject = np.pi * mask[..., None] * colour * BIN * BIN
        front, back, top, bottom = trace_contact(inject, mask, grid, P, rng)
        glow_band = fft_convolve(front, smooth) / (BIN * BIN) / np.pi
        glow_band[:rows] += (top * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        glow_band[-rows:] += (bottom * P["edge_scatter"] / (P["edge_width"] * np.pi))[None]
        onto_foil = np.pi * P["light_back"] * mask[..., None] * colour + fft_convolve(back, smooth) / (BIN * BIN)
        foil_lit = fft_convolve(onto_foil / np.pi, kernel(P["foil_gap"]))
        glow_band += P["foil_front_reflect"] * foil_lit / np.pi * (1 - mask[..., None]) * T_glass
        hot = foil_lit * (1 - P["foil_front_reflect"]) / tau  # so the foil passes tau * hot on, as below
        falling = np.zeros_like(wall_full)
        exitance = embed(tau * hot)
    else:
        glow_band, back, top, bottom, hot = view(np.zeros_like(wall_full), 1.0)
        # Light falling on the wallpaper: the hot light's back; what the foil
        # sends back of the hot light; light out of the glass's back, through
        # the foil.
        falling = fft_convolve(mask_full, kernel(gap - P["light_gap"]))[..., None] * colour
        exitance = embed(refl * hot + tau * fft_convolve(back, smooth) / (BIN * BIN))
    edge_line = np.zeros_like(exitance)
    edge_line[r0] += top[c0:c0 + sw] * P["edge_back"] / BIN
    edge_line[r0 + H - 1] += bottom[c0:c0 + sw] * P["edge_back"] / BIN
    falling += fft_convolve((exitance + edge_line) / np.pi, kernel(gap))
    bleed = falling * albedo / np.pi
    # Seen around the dock, and through it (softened by the foil).
    bleed_band = band(bleed)
    sky = fft_convolve(bleed_band, kernel(gap)) / np.pi
    narrow = fft_convolve(bleed_band, gaussian_kernel(gap * cone, BIN))
    bleed_view = tau * ((1 - wide) * narrow + wide * sky) * T_glass
    return {"glass": (glass_band, wall_full), "glow": (glow_band + bleed_view, bleed)}, grid


if __name__ == "__main__":
    P = {**DEFAULTS, **json.load(open(sys.argv[1]))}
    sim, grid = simulate(P)
    np.save(sys.argv[2] + "-glow.npy", sim["glow"][0])
    fake.save(slab.compose(P, sim, grid), sys.argv[2] + ".png")
