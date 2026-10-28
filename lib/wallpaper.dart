import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'pictures.dart';
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

/// The background: Apple aerials, a video, a picture or a folder of them, or
/// a gradient.
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
                // A new quality or choice of scenes starts over with matching films.
                key: ValueKey('${config.aerialQuality} ${config.aerialsOff.join(',')}'),
                speed: config.aerialSpeed,
                maxLength: config.aerialMinutes > 0 ? Duration(minutes: config.aerialMinutes) : null,
                next: (previous) => s.aerials.next(
                  previous,
                  config.aerialQuality,
                  off: config.aerialsOff,
                  useSaved: config.aerialCache,
                ),
                onShowing: (scene) {
                  s.caption.value = scene.caption;
                  if (config.aerialCache) s.aerials.remember(scene, config.aerialQuality);
                },
              )
            else if (config.wallpaper == 'video' && video != null)
              ScenePlayer(
                key: ValueKey(video),
                speed: config.aerialSpeed,
                next: (_) => Scene(video, '', file: true, loop: true),
              )
            else if (config.wallpaper == 'image' && image != null)
              Pictures.isPicture(image)
                  ? Image.file(File(image), fit: BoxFit.cover, cacheWidth: size.width.round())
                  : PictureShow(
                      key: ValueKey(image),
                      folder: image,
                      every: Duration(minutes: config.pictureMinutes),
                      cacheWidth: size.width.round(),
                    ),
            if (config.dimming > 0) ColoredBox(color: Color.fromRGBO(0, 0, 0, config.dimming)),
          ],
        );
      },
    );
  }
}

/// The pictures in [folder] in a shuffled order, each fading into the next
/// after [every].
class PictureShow extends StatefulWidget {
  const PictureShow({super.key, required this.folder, required this.every, required this.cacheWidth});

  final String folder;
  final Duration every;

  /// Pictures are decoded at the screen's width, however large they are.
  final int cacheWidth;

  @override
  State<PictureShow> createState() => _PictureShowState();
}

class _PictureShowState extends State<PictureShow> {
  List<String> _pictures = const [];
  int _shown = 0;
  Timer? _next;

  @override
  void initState() {
    super.initState();
    Pictures.list(widget.folder).then((found) {
      if (mounted) setState(() => _pictures = found.pictures..shuffle());
    });
    _start();
  }

  @override
  void didUpdateWidget(PictureShow old) {
    super.didUpdateWidget(old);
    if (old.every != widget.every) _start();
  }

  void _start() {
    _next?.cancel();
    _next = Timer.periodic(widget.every, (_) => setState(() => _shown++));
  }

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pictures.isEmpty) return const SizedBox.shrink();
    final path = _pictures[_shown % _pictures.length];
    return AnimatedSwitcher(
      duration: const Duration(seconds: 2),
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: Image.file(File(path), key: ValueKey(path), fit: BoxFit.cover, cacheWidth: widget.cacheWidth),
    );
  }
}
