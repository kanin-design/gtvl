import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// The dock's glow as the app draws it: a lamp behind the frosted glass under
/// the app in focus, as a few closed-form shapes fitted to references traced
/// by tool/glow, drawn by one shader (shaders/glow.frag). All sizes are in dp,
/// light is linear.
class GlowLook {
  const GlowLook({
    required this.core,
    required this.coreBlur,
    required this.pool,
    required this.poolSize,
    required this.poolPower,
    required this.glass,
    required this.glassLength,
    required this.edges,
    required this.edgeLength,
    required this.bleed,
    required this.bleedSize,
    required this.bleedPower,
    required this.bleedTint,
  });

  /// The lamp seen through the frosting: amount, and the frosting's blur.
  final double core, coreBlur;

  /// The frosting's wide light round it: amount, size and power of its falloff.
  final double pool, poolSize, poolPower;

  /// Light carried along the glass, and out at its cut edges: amount and length.
  final double glass, glassLength;
  final double edges, edgeLength;

  /// The light it throws on the wallpaper beyond the dock: amount, size,
  /// power, and its colour (the wallpaper's own tint in it).
  final double bleed, bleedSize, bleedPower;
  final (double, double, double) bleedTint;

  /// The glow setting's levels 1 to 3, faintest first: the light pressed
  /// into the glass (look M1), plus a rising share of the light behind it
  /// (K0), as one lamp glowing behind the glass would add it; each fitted to
  /// its traced reference (tool/glow/ladder.py; `looks/m1-fake.json`, then
  /// `looks/m1-1-fake.json` and `looks/m1-2-fake.json`; the brighter ones
  /// traced there are left out for now).
  static const steps = [
    GlowLook(
      core: 0.1351,
      coreBlur: 16.85,
      pool: 0.2538,
      poolSize: 3.793,
      poolPower: 2.924,
      glass: 0.006896,
      glassLength: 97.43,
      edges: 0.2641,
      edgeLength: 17.96,
      bleed: 0.0166,
      bleedSize: 49.56,
      bleedPower: 1.77,
      bleedTint: (2.782, 0.5639, 0.07387),
    ),
    GlowLook(
      core: 0.0,
      coreBlur: 1.275,
      pool: 0.3217,
      poolSize: 2.633,
      poolPower: 1.053,
      glass: 0.02576,
      glassLength: 41.06,
      edges: 0.2731,
      edgeLength: 15.67,
      bleed: 0.02227,
      bleedSize: 35.4,
      bleedPower: 1.275,
      bleedTint: (2.783, 0.5636, 0.07387),
    ),
    GlowLook(
      core: 0.0,
      coreBlur: 6.0,
      pool: 0.3921,
      poolSize: 2.238,
      poolPower: 0.6375,
      glass: 0.0,
      glassLength: 34.8,
      edges: 0.2766,
      edgeLength: 17.96,
      bleed: 0.0275,
      bleedSize: 35.4,
      bleedPower: 1.275,
      bleedTint: (2.783, 0.5634, 0.07388),
    ),
  ];

  /// The look of the glow setting's [level]: null for 0, off.
  static GlowLook? of(int level) => level <= 0 ? null : steps[math.min(level, steps.length) - 1];

  /// The lamp's size against its app's tile.
  static const lampScale = 1.12;

  /// The tone curve's exposure, and the share of the glow the tiles' edges catch.
  static const exposure = 3.0, rim = 0.25;

  /// Blackbody colours, linear sRGB of luminance 1, from 1000 K by 100 K.
  static const _blackbody = [
    (4.2890, 0.1233, 0.0000),
    (4.0219, 0.2027, 0.0000),
    (3.7739, 0.2764, 0.0000),
    (3.5476, 0.3436, 0.0000),
    (3.3432, 0.4044, 0.0000),
    (3.1592, 0.4591, 0.0000),
    (2.9938, 0.5083, 0.0000),
    (2.8450, 0.5525, 0.0000),
    (2.7109, 0.5924, 0.0000),
    (2.5899, 0.6283, 0.0000),
    (2.4769, 0.6600, 0.0191),
    (2.3739, 0.6884, 0.0411),
    (2.2799, 0.7140, 0.0642),
    (2.1939, 0.7372, 0.0882),
    (2.1150, 0.7581, 0.1131),
    (2.0424, 0.7771, 0.1385),
    (1.9756, 0.7943, 0.1645),
    (1.9138, 0.8100, 0.1909),
    (1.8567, 0.8243, 0.2175),
    (1.8036, 0.8374, 0.2443),
    (1.7543, 0.8493, 0.2712),
    (1.7084, 0.8603, 0.2982),
    (1.6655, 0.8703, 0.3250),
  ];

  /// The lamp's colour at [heat] (1 in focus, more while it flares, less as it
  /// cools): 2300 K at 1, redder as it cools, whiter as it flares.
  static (double, double, double) colour(double heat) {
    final at = ((1000 + 1300 * heat).clamp(1000.0, 3200.0) - 1000) / 100;
    final i = at.floor().clamp(0, _blackbody.length - 2);
    final f = at - i;
    final (r0, g0, b0) = _blackbody[i];
    final (r1, g1, b1) = _blackbody[i + 1];
    return (r0 + (r1 - r0) * f, g0 + (g1 - g0) * f, b0 + (b1 - b0) * f);
  }

  /// What [heat] does to the glow drawn at 1, per channel: below 1 it dims
  /// and reddens as glowing glass does as it cools, through deep red to
  /// nothing, as quickly as the first molten glow did.
  static (double, double, double) fade(double heat) {
    final h = math.max(heat, 0.0);
    return (math.pow(h, 1.45).toDouble(), math.pow(h, 2.5).toDouble(), math.pow(h, 3.2).toDouble());
  }

  /// One lamp's light (luminance, before its heat) at an offset from its
  /// centre, for a lamp of half-sizes [hw], [hh] and corner [r]: what the
  /// shader computes, for the tiles' edges to catch.
  double light(double dx, double dy, double hw, double hh, double r) {
    final qx = dx.abs() - (hw - r), qy = dy.abs() - (hh - r);
    final away = math.max(math.sqrt(math.pow(math.max(qx, 0), 2) + math.pow(math.max(qy, 0), 2)) - r, 0.0);
    return core * _box(dx, hw, coreBlur) * _box(dy, hh, coreBlur) +
        pool * math.pow(1 + (away / poolSize) * (away / poolSize), -poolPower) +
        glass * math.exp(-math.max(dx.abs() - hw, 0) / glassLength);
  }

  static double _box(double u, double h, double s) {
    final k = 0.70710678 / s;
    return 0.5 * (_erf((u + h) * k) - _erf((u - h) * k));
  }

  static double _erf(double x) {
    final s = x.sign;
    x = x.abs();
    final t = 1 / (1 + 0.3275911 * x);
    final y =
        1 -
        (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
            t *
            math.exp(-x * x);
    return s * y;
  }

  /// Linear light as the screen shows it, per channel, through the tone curve.
  static double tone(double light) => 1 - math.exp(-exposure * light);
}

/// The shader, loaded once at start; until then no glow is drawn.
abstract final class GlowShader {
  static ui.FragmentProgram? _program;

  static Future<void> load() async {
    _program ??= await ui.FragmentProgram.fromAsset('shaders/glow.frag');
  }

  static bool get ready => _program != null;

  static ui.FragmentShader? create() => _program?.fragmentShader();
}

/// A lamp along the dock: its centre and heat; an [ember] is going out where
/// focus was.
typedef Spot = ({double x, double heat, bool ember});

/// Sets [shader]'s uniforms to draw one lamp at [x], [y], of [hw] by [hh]
/// half-sizes and corner [r], in [look] and [tint] (its colour times its
/// heat), in a [size] area whose band runs from [top] to [bottom]: the
/// glass's own light, or with [wallpaper], the light the lamp throws on the
/// wallpaper beyond the band.
void setGlow(
  ui.FragmentShader shader,
  Size size, {
  required GlowLook look,
  required double x,
  required double y,
  required double hw,
  required double hh,
  required double r,
  required double top,
  required double bottom,
  required (double, double, double) tint,
  bool wallpaper = false,
}) {
  var i = 0;
  void put(Iterable<double> values) {
    for (final v in values) {
      shader.setFloat(i++, v);
    }
  }

  final (tr, tg, tb) = tint;
  put([size.width, size.height]);
  put([x, y, hw, hh]);
  put([r, top, bottom, GlowLook.exposure]);
  put([look.core, look.coreBlur, look.pool, look.poolSize]);
  put([look.poolPower, look.glass, look.glassLength, look.edges]);
  put([look.edgeLength, look.bleed, look.bleedSize, look.bleedPower]);
  put([tr, tg, tb, wallpaper ? 1 : 0]);
}

/// What a [GlowSprite] is drawn for: the look; the lamp's half-sizes and
/// corner; the image's height, the lamp's centre and the band's top and
/// bottom in it (dp); the wallpaper's light or the glass's; pixels a dp.
typedef GlowKey = ({
  GlowLook look,
  double hw,
  double hh,
  double r,
  double height,
  double y,
  double top,
  double bottom,
  bool wallpaper,
  double ratio,
});

/// One lamp's glow, drawn once by the shader into images reaching [reach]
/// either side of it, at the heat of an app in focus; flared too, for while
/// OK is held; and in the glass softened, for a lamp going out, which
/// softens as it dims so that no outline stays round the app it was behind.
/// The glow is the same behind every app, so a frame only places it, dimmed
/// and reddened by its heat: next to nothing for a slow TV.
class GlowSprite {
  GlowSprite._(this.key, this._shaders, this.image, this.flared, this.soft);

  final GlowKey key;
  final List<ui.FragmentShader> _shaders;

  /// At the heat of an app in focus, at [flare], and softened for a lamp going out.
  final ui.Image image;
  final ui.Image? flared, soft;

  /// How far it reaches either side of its lamp (dp): the glow is gone by then.
  static const reach = 600.0;

  /// The heat of an app in focus while OK is held.
  static const flare = 1.35;

  /// How much a lamp going out has softened by the time it is out (dp).
  static const _softness = 10.0;

  /// Draws them for [key]; null until the shader has loaded.
  static GlowSprite? draw(GlowKey key) {
    if (!GlowShader.ready || key.height <= 0 || key.ratio <= 0) return null;
    final shaders = <ui.FragmentShader>[];
    final size = Size(2 * reach, key.height);
    ui.Image render(double heat) {
      final shader = GlowShader.create()!;
      shaders.add(shader);
      final (cr, cg, cb) = key.wallpaper ? key.look.bleedTint : GlowLook.colour(heat);
      setGlow(
        shader,
        size,
        look: key.look,
        x: reach,
        y: key.y,
        hw: key.hw,
        hh: key.hh,
        r: key.r,
        top: key.top,
        bottom: key.bottom,
        tint: (cr * heat, cg * heat, cb * heat),
        wallpaper: key.wallpaper,
      );
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..scale(key.ratio)
        ..drawRect(Offset.zero & size, Paint()..shader = shader);
      return _image(recorder, size * key.ratio);
    }

    final image = render(1);
    if (key.wallpaper) return GlowSprite._(key, shaders, image, null, null);
    final blur = _softness * key.ratio;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      image,
      Offset.zero,
      Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.decal),
    );
    return GlowSprite._(key, shaders, image, render(flare), _image(recorder, size * key.ratio));
  }

  static ui.Image _image(ui.PictureRecorder recorder, Size pixels) {
    final picture = recorder.endRecording();
    final image = picture.toImageSync(pixels.width.ceil(), pixels.height.ceil());
    picture.dispose();
    return image;
  }

  /// Adds the lamp centred at [x] to [canvas], its image's top at [top]: at
  /// [heat] (dimmed and reddened below 1, flaring above), times [opacity];
  /// an [ember], going out, softening as it dims.
  void place(Canvas canvas, double x, double top, {required double heat, bool ember = false, double opacity = 1}) {
    final dst = Rect.fromLTWH(x - reach, top, 2 * reach, key.height);
    // Its pixels as drawn, one to one: the image has whole pixels, a little more.
    final src = Rect.fromLTWH(0, 0, 2 * reach * key.ratio, key.height * key.ratio);
    void add(ui.Image image, (double, double, double) by) {
      final (r, g, b) = by;
      if (r <= 0) return;
      canvas.drawImageRect(
        image,
        src,
        dst,
        Paint()
          ..blendMode = BlendMode.plus
          ..filterQuality = FilterQuality.low
          // Its colours times r, g and b: the image's colours are premultiplied by its alpha.
          ..colorFilter = ColorFilter.mode(Color.from(alpha: r, red: 1, green: g / r, blue: b / r), BlendMode.modulate),
      );
    }

    final flared = this.flared;
    if (heat > 1 && flared != null && !ember) {
      final t = ((heat - 1) / (flare - 1)).clamp(0.0, 1.0);
      add(image, ((1 - t) * opacity, (1 - t) * opacity, (1 - t) * opacity));
      add(flared, (t * opacity, t * opacity, t * opacity));
      return;
    }
    final h = math.min(heat, 1.0);
    final (r, g, b) = GlowLook.fade(h);
    // Going out, its light softens as it dims: from the lamp's own to the softened.
    for (final (image, share) in [(image, ember ? h : 1.0), (soft ?? image, ember ? 1 - h : 0.0)]) {
      if (share > 0) add(image, (r * opacity * share, g * opacity * share, b * opacity * share));
    }
  }

  void dispose() {
    image.dispose();
    flared?.dispose();
    soft?.dispose();
    for (final shader in _shaders) {
      shader.dispose();
    }
  }
}
