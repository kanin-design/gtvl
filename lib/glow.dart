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

  /// The glow setting's steps, faintest first: the light pressed into the
  /// glass (look M1), plus a rising share of the light behind it (K0), as
  /// one lamp glowing behind the glass would add it; each fitted to its
  /// traced reference (tool/glow/ladder.py; `looks/m1-fake.json` for 0, then
  /// `looks/m1-<step>-fake.json`).
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
    GlowLook(
      core: 0.0,
      coreBlur: 0.885,
      pool: 0.4747,
      poolSize: 2.168,
      poolPower: 0.6214,
      glass: 0.009526,
      glassLength: 10.53,
      edges: 0.2743,
      edgeLength: 18.49,
      bleed: 0.0387,
      bleedSize: 35.4,
      bleedPower: 1.5,
      bleedTint: (2.784, 0.5632, 0.0739),
    ),
    GlowLook(
      core: 0.2845,
      coreBlur: 11.7,
      pool: 0.4904,
      poolSize: 1.51,
      poolPower: 0.5419,
      glass: 0.0,
      glassLength: 49.56,
      edges: 0.2766,
      edgeLength: 18.43,
      bleed: 0.04944,
      bleedSize: 35.4,
      bleedPower: 1.5,
      bleedTint: (2.784, 0.5631, 0.07392),
    ),
    GlowLook(
      core: 0.2617,
      coreBlur: 1.032,
      pool: 0.5337,
      poolSize: 5.419,
      poolPower: 1.084,
      glass: 0.0296,
      glassLength: 60.18,
      edges: 0.2901,
      edgeLength: 18.43,
      bleed: 0.06373,
      bleedSize: 35.4,
      bleedPower: 1.5,
      bleedTint: (2.784, 0.5631, 0.07395),
    ),
    GlowLook(
      core: 0.06467,
      coreBlur: 0.3061,
      pool: 0.8172,
      poolSize: 3.761,
      poolPower: 0.7522,
      glass: 0.01107,
      glassLength: 58.48,
      edges: 0.2971,
      edgeLength: 18.97,
      bleed: 0.08288,
      bleedSize: 35.4,
      bleedPower: 1.5,
      bleedTint: (2.784, 0.5632, 0.07399),
    ),
  ];

  /// The look of the glow setting's [step].
  static GlowLook at(int step) => steps[step.clamp(0, steps.length - 1)];

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

/// The shader, loaded once at start; null until then, when no glow is drawn.
abstract final class GlowShader {
  static ui.FragmentProgram? _program;

  static Future<void> load() async {
    _program ??= await ui.FragmentProgram.fromAsset('shaders/glow.frag');
  }

  static ui.FragmentShader? create() => _program?.fragmentShader();
}

/// A lamp to draw: its centre along the dock, heat and stretch.
typedef Spot = ({double x, double heat, double stretch});

/// Sets [shader]'s uniforms to draw up to four [spots] in a [size] area whose
/// band runs from [top] to [bottom], lamps centred at [y], of [hw] by [hh]
/// half-sizes and corner [r], in [look]: the glass's own light, or with
/// [wallpaper], the light the lamps throw on the wallpaper beyond the band.
void setGlow(
  ui.FragmentShader shader,
  Size size, {
  required GlowLook look,
  required double y,
  required double hw,
  required double hh,
  required double r,
  required double top,
  required double bottom,
  required List<Spot> spots,
  bool wallpaper = false,
}) {
  var i = 0;
  void put(Iterable<double> values) {
    for (final v in values) {
      shader.setFloat(i++, v);
    }
  }

  put([size.width, size.height]);
  put([y, hw, hh, r]);
  put([look.core, look.coreBlur, look.pool, look.poolSize]);
  put([look.poolPower, look.glass, look.glassLength, look.edges]);
  put([look.edgeLength, top, bottom, GlowLook.exposure]);
  put([look.bleed, look.bleedSize, look.bleedPower, wallpaper ? 1 : 0]);
  for (var k = 0; k < 4; k++) {
    final spot = k < spots.length ? spots[k] : null;
    if (spot == null || spot.heat <= 0) {
      put([0, 0, 1, 0, 0, 0, 0, 0]);
      continue;
    }
    final (cr, cg, cb) = wallpaper ? look.bleedTint : GlowLook.colour(spot.heat);
    put([spot.x, spot.heat, spot.stretch, 0, cr, cg, cb, 0]);
  }
}
