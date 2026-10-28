import 'dart:io';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'ui.dart';

/// An app on the home screen: its TV banner, or its icon and name on a card.
///
/// Focus lifts the tile toward the viewer: it grows, casts a soft shadow and
/// catches a sheen of light. No outline.
class AppTile extends StatelessWidget {
  const AppTile({
    super.key,
    required this.app,
    required this.onLaunch,
    required this.onMenu,
    this.autofocus = false,
    this.label = false,
    this.moving = false,
    this.onKey,
  });

  final AppInfo app;
  final VoidCallback onLaunch;
  final VoidCallback onMenu;
  final bool autofocus;

  /// Shows the app's name under the tile while it has focus.
  final bool label;

  /// Being moved in the dock: stays lifted and shows arrows.
  final bool moving;
  final KeyEventResult Function(KeyEvent event)? onKey;

  static final _radius = BorderRadius.circular(10);
  static const _lifted = [BoxShadow(color: Color(0x8C000000), blurRadius: 22, offset: Offset(0, 10))];
  static const _sheen = DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment(0.3, 0.8),
        colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: onLaunch,
    onLongPress: onMenu,
    onKey: onKey,
    builder: (context, focused) {
      final lift = focused || moving;
      final tile = AnimatedScale(
        scale: lift ? 1.1 : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.fast,
          curve: Look.ease,
          decoration: BoxDecoration(borderRadius: _radius, boxShadow: lift ? _lifted : const []),
          child: ClipRRect(
            borderRadius: _radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                TileFace(app),
                AnimatedOpacity(opacity: lift ? 1 : 0, duration: Look.fast, child: _sheen),
                if (moving)
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(Icons.chevron_left, color: Look.white, shadows: Look.shadow),
                      Icon(Icons.chevron_right, color: Look.white, shadows: Look.shadow),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
      if (!label) return tile;
      return Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: tile),
          const SizedBox(height: 8),
          AnimatedOpacity(
            opacity: focused ? 1 : 0,
            duration: Look.fast,
            child: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: Look.label),
          ),
        ],
      );
    },
  );
}

/// The picture on a tile: the TV banner, or the icon and name on a dark card
/// for apps made for phones. Decoded at the size it is drawn.
class TileFace extends StatelessWidget {
  const TileFace(this.app, {super.key});

  final AppInfo app;

  @override
  Widget build(BuildContext context) {
    final path = app.tilePath;
    if (path == null) {
      return FutureBuilder<String?>(future: app.tile, builder: (context, _) => _face(context, app.tilePath));
    }
    return _face(context, path);
  }

  Widget _face(BuildContext context, String? path) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (path != null && path.endsWith('.b.png')) {
      return LayoutBuilder(
        builder: (context, box) =>
            Image.file(File(path), fit: BoxFit.cover, cacheWidth: (box.maxWidth * dpr).round(), gaplessPlayback: true),
      );
    }
    return ColoredBox(
      color: const Color(0xFF2A2C31),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            if (path != null)
              Image.file(File(path), width: 30, height: 30, cacheWidth: (30 * dpr).round())
            else
              const Icon(Icons.apps, size: 28, color: Look.dim),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                app.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Look.small.copyWith(color: Look.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
