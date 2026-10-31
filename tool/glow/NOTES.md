# The dock's glow: where it stands

Branch `dev`. The goal: a reference look for the glow behind the app in focus, then a cheap
fake in the app that looks like it.

## Status: the M1 ladder (2026-10-31)

- The user meant their two picks to be combined: k01 (K0) too bright, m01 too dim. Of the six
  candidates they like M1 best, and asked for M1 lit brighter in steps 0 to 6, "glass lit from
  behind by some source like a glowing radio tube".
- `ladder.py` lights traced looks together. Step k is M1 plus K0's light from behind the glass
  at a share of 0, 0.069, 0.164, 0.288, 0.46, 0.69, 1.0 (looks/m1-<k>.json; step 0 is M1 itself).
  The shares make the light just outside the app rise about 1.35 times a step, from M1's level
  to M1 + K0 at 6 (the too-bright end); step 3 is halfway in brightness.
- Turning M1 itself up was tried and dropped: it only makes the outline hotter and shows the
  trace's grain in the glass. It reads as a neon outline, not glass lit from behind.
- Each step's fake is fitted (fit.py takes a "mix" look): looks/m1-<k>-fake.json, errors 0.015
  to 0.023, close to the reference at full size. Sheet: out/m1-ladder.png, reference beside fake.
- The glow is now a setting: Settings, Dock, Glow, steps 0 to 6 (Config.glow, default 1, the
  user's latest try after 4 and 2 felt too much). GlowLook.steps in lib/glow.dart holds all
  seven fits (step 0 from looks/m1-fake.json, step k from looks/m1-k-fake.json); refit a step
  by running fit.py on its look and copying the numbers over.
- Drawn once (2026-10-31, for slow TVs): the shader no longer runs every frame. GlowSprite
  (lib/glow.dart) draws one lamp's light into images when the dock or the setting changes:
  the glass at the heat of focus, flared (OK held), softened by a 10 dp blur for embers, and
  the wallpaper's light at half the pixels. Each frame only places them with plus blending,
  dimmed and reddened by GlowLook.fade (heat^1.45, ^2.5, ^3.2 per channel, the first molten
  glow's cooling). Against the per-frame shader: a quarter of a level apart on average.
- The setting, for now (the user, 2026-10-31): Off, 1, 2, 3 (Config.dockGlow, default 2).
  Levels 1 to 3 are the old steps 0 to 2 (M1, M1 + K0 x0.069, M1 + K0 x0.164); the brighter
  steps' fits stay in looks/ but not in the app. Off draws no glow, and the dock's apps take
  focus as they do elsewhere (shadow and sheen).
- No flow (the user, 2026-10-31: "it should just pop up behind the selected card, as if a
  bulb was lit, then fade out fast behind the last one"). _Molten lights a lamp behind the new
  app from dark (rate 25/s: full in about 80 ms, up through red) and leaves the old one going
  out where it was (rate 8/s, gone in about 250 ms), softening as it dims. Same when focus
  leaves the dock. Shield: out/shield-bulb.png; moves still at 60 fps.
- The fade, put back: embers had been drawn as the full lamp, so a crisp ring stayed round
  the app left behind, and luminance-normalised blackbody colours kept the cooling glow
  bright red. Now an ember is soft warm glass, gone within about 200 ms of a move
  (out/shield-fade.png, frames from the Shield).
- On the Shield (2026-10-31): the build with the setting, at step 1. Each focus move still
  plays as 50 unbroken frames at 60 fps (measure.sh); between moves the video's own 30 fps.
- The user tried step 4 on the emulator (AVD shieldtv) and found it too bright, then step 2. Step 4 was drawn correctly: beside the app, the
  emulator added the same light as the sheet's step 4 within a few levels. The emulator's
  wallpaper is a daytime photo, so its dock's glass is olive (about 50/255) where the Arc fold
  frame's is near black, and the glow adds on top of that, turning yellow sooner. The Shield
  still has the K0 build. The shader's code is unchanged,
  only its numbers, so the Shield's 60 fps measurement still holds. To switch steps, copy that
  step's fake.json into GlowLook (light_scale into lampScale, bleed_colour into bleedTint), then
  rebuild.

## Earlier status: six candidates

- The user found A6 + C1 (below) too strong. Re-rendered their two picks unchanged (K0 = k01,
  the light behind the foil; M0 = m01, the light pressed into the glass) next to small steps
  (originals.py), sent as one sheet; their pick is open. The fake is fitted to K0 meanwhile.
- `fit.py looks/k0.json k0` fitted the analytic fake: looks/k0-fake.json, out/k0-pair.png
  (reference over fake, near identical). Refit for another pick by making its look file.
- In the app: shaders/glow.frag draws it (lib/glow.dart holds the fitted numbers, the
  blackbody colours and the tiles' warm edge), home.dart's _MoltenPainter in the glass and
  _BleedPainter for the wallpaper under the dock. On the Shield: matches the reference at the
  same scale; every move plays as 50 unbroken frames at 60 fps (SurfaceFlinger latency).
- All six candidates are fitted too (looks/<name>.json and <name>-fake.json; out/all-pairs.png
  shows each reference beside its fake). Switching the app's look: copy that fake.json's
  numbers into GlowLook in lib/glow.dart (light_scale into lampScale), rebuild.
- Not done: the TCL (off), the user's pick between K0/K1/K2/M0/M1/M2, a commit.

## Earlier: redo the reference (done)

The user saw out/reference.png full screen: "it doesn't look as good as the ones I sent you
before... I sent you two. This is too strong." Their two: k01 (guide.py light behind the foil,
DEFAULTS with light_mode "behind": light_gap 24, light_scale 1.15, light_radiance 1.6,
glass_mfp 150, wall_gap 60) and m01 (light_mode "inject", glass_mfp 300, light_radiance 1.0,
light_scale 1.12). Start from exactly those two, at their strength: render each unchanged next
to small steps only (the light a little further back at the same or lower strength), show
them beside the originals, and let the user pick before fitting the fake. A6 + C1 is too strong
and is not the reference.

## The reference as first chosen (too strong; see above)

- `looks/reference.json`: guide.py's light behind the foil (A6) plus half of its light pressed
  into the glass (C1), lit together by `both.py`. Render: `out/reference.png` (1920x1080).
- The user liked two looks and asked to polish them, not to build new models: the soft glow
  (light behind the foil, now further back and softer) and the injected edge lines. frost.py
  and glass.py are parked experiments; guide.py, both.py, sheet.py and fake.py are the tools.
- Its light layers, linear, on guide.py's 0.5 dp grid: `out/ref-glow-band.npy` (the dock band,
  x from -40 dp, 172 x 2080), `out/ref-glow-full.npy` (the wallpaper's glow, 1080 x 1920),
  `out/ref-lamp-band.npy` and `out/ref-inject-band.npy` (its two parts).

## Measured (luminance, the tile in focus centred at 212.7, 459.3 dp; lifted half-width 55.5 dp)

- Middle row, dp from the centre: 0: 1.16, 55: 0.70, 62: 0.47, 70: 0.26, 80: 0.12, 95: 0.058,
  120: 0.026, 150: 0.013, 200: 0.0043, 300: 0.0011.
- Top edge (rows 0-1): 0: 0.59, 70: 0.18, 100: 0.054, 150: 0.026, 200: 0.0125, 300: 0.0075,
  450: 0.0058, 600: 0.0034 (the long tail is the injected light).
- Across the band 8 dp right of the tile: peak 0.41 mid-height, 0.24 at the top edge, 0.13 at
  the bottom.
- Wallpaper above the band: 1 dp: 0.068, 10: 0.055, 20: 0.045, 40: 0.025, 70: 0.0067, 100: 0.0033.
- Display: screen = sRGB(glass) + look.tone(glow, exposure 3), tone = 1 - exp(-3 L) per channel,
  colour a 2300 K blackbody.

## The fake (next)

1. In numpy first: an analytic glow (blurred rounded rect as erf products, a wide soft
   falloff, the rim, the edge lines with an exponential tail, light spread in the glass) plus
   the wallpaper's glow; fit its few numbers to the reference in display space, outside the
   tiles; compare side by side with out/reference.png.
2. In the app: one fragment shader drawing the in-glass glow with the same tone curve, added
   (plus) under the tiles; a second layer under the dock for the wallpaper's glow, so the
   glass's blur softens it. Keep the _Molten controller (flow, embers, cooling, flare).
3. Check against the reference on the emulator, then the Shield: look, and 60 fps measured
   with SurfaceFlinger latency and the frame timings (no frame over 16.7 ms).
