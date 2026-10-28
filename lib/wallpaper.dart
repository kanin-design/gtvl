import 'dart:io';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'player.dart';
import 'services.dart';

/// Gradient wallpapers: name and colours.
const gradients = <(String, List<Color>)>[
  ('Night', [Color(0xFF0B1220), Color(0xFF1B2A41), Color(0xFF324A5F)]),
  ('Ocean', [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)]),
  ('Dusk', [Color(0xFF2B1B3D), Color(0xFF5B2A5C), Color(0xFFB0544B)]),
  ('Forest', [Color(0xFF0B1F17), Color(0xFF1E3B2C), Color(0xFF3F6B4F)]),
  ('Graphite', [Color(0xFF111214), Color(0xFF26282C), Color(0xFF3A3D42)]),
];

/// The background: Apple aerials, a video or picture file, or a gradient.
/// The gradient also shows while a video loads, or if it cannot play.
class Wallpaper extends StatelessWidget {
  const Wallpaper({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: s.config,
      builder: (context, _) {
        final config = s.config;
        final colors = gradients[config.gradient.clamp(0, gradients.length - 1)].$2;
        final video = config.videoPath;
        final image = config.imagePath;
        final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
        return Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
              ),
            ),
            if (config.wallpaper == 'aerials')
              ScenePlayer(
                // A new quality starts over with films in that quality.
                key: ValueKey(config.aerialQuality),
                next: (previous) => s.aerials.next(previous, config.aerialQuality),
                onShowing: (scene) {
                  s.caption.value = scene.caption;
                  s.aerials.remember(scene, config.aerialQuality);
                },
              )
            else if (config.wallpaper == 'video' && video != null)
              ScenePlayer(key: ValueKey(video), next: (_) => Scene(video, '', file: true, loop: true))
            else if (config.wallpaper == 'image' && image != null)
              Image.file(File(image), fit: BoxFit.cover, cacheWidth: size.width.round()),
          ],
        );
      },
    );
  }
}
