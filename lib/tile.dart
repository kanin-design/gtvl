import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'glow.dart';
import 'ui.dart';

/// The dock's light, as a tile sees it: which tile the lamp behind the glass
/// is behind, by index; how hot it is (1 in focus, more while it flares,
/// less while it comes on or goes out); the distance from one app's centre
/// to the next; and its look.
class Glow {
  const Glow(this.at, this.heat, this.step, this.look);

  final double at, heat, step;
  final GlowLook look;

  @override
  bool operator ==(Object other) =>
      other is Glow && other.at == at && other.heat == heat && other.step == step && other.look == look;

  @override
  int get hashCode => Object.hash(at, heat, step, look);
}

/// An app on the home screen: its TV banner, or its icon and name on a card;
/// with [square], its icon in a rounded square.
///
/// Focus lifts the tile toward the viewer on a spring: it grows, its shadow
/// deepens, light runs along its rim, brightest at the top left, and a soft
/// sheen crosses its face. At rest a faint rim of the same light keeps dark
/// icons in shape on dark glass. OK sinks it a little. No outline.
///
/// In the dock's glass ([glow]), focus lifts it in front of the lamp glowing
/// behind the glass instead: no shadow or sheen, and its edge catches the
/// glow behind it, as every tile's does, most on the side toward the lamp.
class AppTile extends StatelessWidget {
  const AppTile({
    super.key,
    required this.app,
    required this.onLaunch,
    required this.onMenu,
    this.square = false,
    this.radius = 10,
    this.autofocus = false,
    this.label = false,
    this.moving = false,
    this.onKey,
    this.onFocusChange,
    this.onDown,
    this.glow,
    this.index = 0,
  });

  final AppInfo app;
  final VoidCallback onLaunch;
  final VoidCallback onMenu;
  final bool square;
  final double radius;
  final bool autofocus;

  /// Shows the app's name under the tile while it has focus.
  final bool label;

  /// Being moved in the dock: stays lifted and shows arrows.
  final bool moving;
  final KeyEventResult Function(KeyEvent event)? onKey;
  final ValueChanged<bool>? onFocusChange;

  /// OK went down (true) or came up (false) on it.
  final ValueChanged<bool>? onDown;

  /// The dock's glow, and this tile's place among the dock's apps.
  final ValueListenable<Glow?>? glow;
  final int index;

  /// Lifted, a tile casts two shadows, a close one and a wide soft one, as a
  /// real object does; at rest it lies flat on the glass.
  static const _lifted = [
    BoxShadow(color: Color(0x40000000), blurRadius: 10, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x8C000000), blurRadius: 34, offset: Offset(0, 18)),
  ];

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: onLaunch,
    onLongPress: onMenu,
    onKey: onKey,
    onFocusChange: onFocusChange,
    onDown: onDown,
    dip: true,
    builder: (context, focused) {
      final lift = focused || moving;
      final corners = BorderRadius.circular(radius);
      // Squares get smooth, continuous corners, like Apple's app icons.
      final ShapeBorder shape = square
          ? RoundedSuperellipseBorder(borderRadius: corners)
          : RoundedRectangleBorder(borderRadius: corners);
      final face = Stack(
        fit: StackFit.expand,
        children: [
          TileFace(app, square: square),
          if (moving)
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.chevron_left_rounded, color: Look.white, shadows: Look.shadow),
                Icon(Icons.chevron_right_rounded, color: Look.white, shadows: Look.shadow),
              ],
            ),
        ],
      );
      // How lifted, 0 at rest to 1 in focus: up on a spring, down more quietly.
      final tile = TweenAnimationBuilder<double>(
        tween: Tween(end: lift ? 1 : 0),
        duration: lift ? const Duration(milliseconds: 360) : const Duration(milliseconds: 200),
        curve: lift ? const _Spring() : Curves.easeOutCubic,
        child: square
            ? ClipRSuperellipse(borderRadius: corners, child: face)
            : ClipRRect(borderRadius: corners, child: face),
        builder: (context, t, picture) {
          final lifted = t.clamp(0.0, 1.0);
          final glow = this.glow;
          // Drawn over the picture, inside the tile.
          Widget lit(Glow? hot) => CustomPaint(
            foregroundPainter: _Light(
              corners,
              glow == null ? lifted : 0,
              square: square,
              glow: hot,
              index: index,
              scale: 1 + 0.12 * t,
            ),
            child: picture,
          );
          return Transform.scale(
            scale: 1 + 0.12 * t,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                shadows: glow == null ? BoxShadow.lerpList(const [], _lifted, lifted) : const [],
              ),
              child: glow == null
                  ? lit(null)
                  : ValueListenableBuilder<Glow?>(valueListenable: glow, builder: (context, hot, _) => lit(hot)),
            ),
          );
        },
      );
      if (!label) return tile;
      return LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            AspectRatio(aspectRatio: square ? 1 : 16 / 9, child: tile),
            const SizedBox(height: 8),
            // A name may reach a little past its tile, a narrow square's further.
            OverflowBox(
              maxWidth: box.maxWidth * (square ? 1.8 : 1.4),
              fit: OverflowBoxFit.deferToChild,
              // Rises into place as it fades in, with the tile's lift.
              child: AnimatedSlide(
                offset: focused ? Offset.zero : const Offset(0, -0.35),
                duration: Look.medium,
                curve: Look.ease,
                child: AnimatedOpacity(
                  opacity: focused ? 1 : 0,
                  duration: focused ? Look.medium : Look.fast,
                  curve: Look.ease,
                  child: Text(
                    app.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Look.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Light on a tile, from the top left: a rim along its edge, faint at rest and
/// bright in focus, and in focus a soft sheen across its face. [lift] goes
/// from 0 at rest to 1 in focus.
///
/// With the dock's [glow]: its outer dp catches a share of the glass's glow
/// behind it (see glow.dart), most on the side toward the lamp. [scale] is
/// how much the tile is enlarged.
///
/// Every shape is drawn as a rounded rectangle or superellipse, never a
/// path: a TV redraws the dock every frame while its glow moves, and works
/// out a path's outline afresh each time.
class _Light extends CustomPainter {
  _Light(this.corners, this.lift, {required this.square, this.glow, this.index = 0, this.scale = 1});

  final BorderRadius corners;
  final bool square;
  final double lift, scale;
  final Glow? glow;
  final int index;

  static Color _white(double alpha) => Color.fromRGBO(255, 255, 255, alpha);

  /// The tile's outline fitted to [rect], filled or stroked by [paint].
  void _outline(Canvas canvas, Rect rect, Paint paint) => square
      ? canvas.drawRSuperellipse(corners.toRSuperellipse(rect), paint)
      : canvas.drawRRect(corners.toRRect(rect), paint);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final width = 1 + 0.25 * lift;
    // Brightest at the top left, almost gone across the middle, and a faint
    // glint again at the far corner, as light runs through glass.
    _outline(
      canvas,
      rect.deflate(width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_white(0.22 + 0.42 * lift), _white(0.06 + 0.06 * lift), _white(0.08 + 0.12 * lift)],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    if (lift > 0) {
      _outline(
        canvas,
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: const Alignment(-0.1, 0.1),
            colors: [_white(0.09 * lift), _white(0)],
          ).createShader(rect),
      );
    }
    final glow = this.glow;
    if (glow == null || glow.heat < 0.01 || glow.step <= 0) return;
    // The lamp is as big as the tile, enlarged as the shader has it; this
    // tile's centre, and its left and right edges, as offsets from it.
    final hw = size.width * GlowLook.lampScale / 2, hh = size.height * GlowLook.lampScale / 2;
    final r = corners.topLeft.x * GlowLook.lampScale;
    final centre = (index - glow.at) * glow.step;
    final half = size.width * scale / 2;
    // As the glow behind it: drawn at the heat of focus, then faded with the heat.
    final (cr, cg, cb) = GlowLook.colour(1);
    final (fr, fg, fb) = GlowLook.fade(glow.heat);
    Color caught(double dx) {
      final light = GlowLook.rim * glow.look.light(dx, 0, hw, hh, r);
      int channel(double c, double f) => (255 * math.min(GlowLook.tone(light * c) * f, 1.0)).round();
      return Color.fromARGB(255, channel(cr, fr), channel(cg, fg), channel(cb, fb));
    }

    _outline(
      canvas,
      rect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..blendMode = BlendMode.plus
        ..shader = LinearGradient(colors: [caught(centre - half), caught(centre + half)]).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_Light old) =>
      old.lift != lift ||
      old.scale != scale ||
      old.corners != corners ||
      old.square != square ||
      old.glow != glow ||
      old.index != index;
}

/// A damped spring: quick off the mark, a touch past it, then settled, as a
/// tile lifted toward the viewer does.
class _Spring extends Curve {
  const _Spring();

  static const _damping = 0.65, _frequency = 11.0;
  static final _ringing = _frequency * math.sqrt(1 - _damping * _damping);

  @override
  double transformInternal(double t) =>
      1 -
      math.exp(-_damping * _frequency * t) *
          (math.cos(_ringing * t) + _damping * _frequency / _ringing * math.sin(_ringing * t));
}

/// The picture on a tile: the TV banner, or the icon and name on a dark card
/// for apps made for phones; with [square], the icon filling the tile.
/// Decoded at the size it is drawn.
class TileFace extends StatelessWidget {
  const TileFace(this.app, {super.key, this.square = false});

  final AppInfo app;
  final bool square;

  static const _card = Color(0xFF2A2C31);

  @override
  Widget build(BuildContext context) {
    final path = square ? app.iconPath : app.tilePath;
    if (path != null) return _face(context, path);
    return FutureBuilder<String?>(
      future: square ? app.icon : app.tile,
      builder: (context, loaded) => _face(context, loaded.data),
    );
  }

  Widget _face(BuildContext context, String? path) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Banners and square icons fill the tile.
    if (path != null && !path.endsWith('.i.png')) {
      return LayoutBuilder(
        builder: (context, box) => Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: (box.maxWidth * dpr).round(),
          gaplessPlayback: true,
          // A file gone or spoilt (the cache cleared, power lost mid-write): the card, not a blank tile.
          errorBuilder: (context, _, _) => _face(context, null),
        ),
      );
    }
    if (square) return const ColoredBox(color: _card);
    return ColoredBox(
      color: _card,
      child: LayoutBuilder(
        builder: (context, box) {
          // On a narrow card the name goes under the icon, on one line: beside
          // it, a word too long for the line would break in two.
          final narrow = box.maxWidth < 170;
          final height = box.maxHeight.isFinite ? box.maxHeight : box.maxWidth * 9 / 16;
          final size = narrow ? (height * 0.34).clamp(12.0, 30.0) : 30.0;
          final placeholder = Icon(Icons.apps, size: size - 2, color: Look.dim);
          final icon = path != null
              ? Image.file(
                  File(path),
                  width: size,
                  height: size,
                  cacheWidth: (size * dpr).round(),
                  errorBuilder: (context, _, _) => placeholder,
                )
              : placeholder;
          final name = Text(
            app.label,
            maxLines: narrow ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            textAlign: narrow ? TextAlign.center : TextAlign.start,
            style: Look.small.copyWith(color: Look.white, fontSize: narrow ? (height * 0.2).clamp(11.0, 13.0) : null),
          );
          if (!narrow) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 10),
                  Expanded(child: name),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                SizedBox(height: height * 0.05),
                name,
              ],
            ),
          );
        },
      ),
    );
  }
}
