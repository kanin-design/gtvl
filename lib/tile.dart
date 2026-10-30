import 'dart:io';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'ui.dart';

/// An app on the home screen: its TV banner, or its icon and name on a card;
/// with [square], its icon in a rounded square.
///
/// Focus lifts the tile toward the viewer: it grows, casts a soft shadow,
/// and light catches its edge. Every tile has a faint edge, so dark icons
/// keep their shape on dark glass. OK sinks it a little. No outline, no gloss.
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

  static const _lifted = [BoxShadow(color: Color(0xA6000000), blurRadius: 30, offset: Offset(0, 14))];
  static const _edge = Color(0x24FFFFFF), _litEdge = Color(0x52FFFFFF);

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: onLaunch,
    onLongPress: onMenu,
    onKey: onKey,
    dip: true,
    builder: (context, focused) {
      final lift = focused || moving;
      final corners = BorderRadius.circular(radius);
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
      final edge = BorderSide(color: lift ? _litEdge : _edge);
      final tile = AnimatedScale(
        scale: lift ? 1.12 : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.fast,
          curve: Look.ease,
          // Squares get smooth, continuous corners, like Apple's app icons.
          decoration: square
              ? ShapeDecoration(
                  shape: RoundedSuperellipseBorder(borderRadius: corners),
                  shadows: lift ? _lifted : const [],
                )
              : BoxDecoration(borderRadius: corners, boxShadow: lift ? _lifted : const []),
          // The edge is drawn over the picture, inside the tile.
          foregroundDecoration: square
              ? ShapeDecoration(
                  shape: RoundedSuperellipseBorder(borderRadius: corners, side: edge),
                )
              : BoxDecoration(borderRadius: corners, border: Border.fromBorderSide(edge)),
          child: square
              ? ClipRSuperellipse(borderRadius: corners, child: face)
              : ClipRRect(borderRadius: corners, child: face),
        ),
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
              child: AnimatedOpacity(
                opacity: focused ? 1 : 0,
                duration: Look.fast,
                child: Text(
                  app.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Look.label.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
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
        builder: (context, box) =>
            Image.file(File(path), fit: BoxFit.cover, cacheWidth: (box.maxWidth * dpr).round(), gaplessPlayback: true),
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
          final icon = path != null
              ? Image.file(File(path), width: size, height: size, cacheWidth: (size * dpr).round())
              : Icon(Icons.apps, size: size - 2, color: Look.dim);
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
