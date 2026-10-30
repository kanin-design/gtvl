import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'config.dart';
import 'deck.dart';
import 'media.dart';
import 'native.dart';
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

/// The quiet dark gradient under films and pictures.
final _graphite = gradients.firstWhere((gradient) => gradient.$1 == 'Graphite').$2;

/// The background: Apple aerials, videos, pictures, or a gradient.
/// Under films and pictures lies a quiet dark one (Graphite), which shows
/// while the first film loads, or if none can play: not a coloured gradient
/// flashing up at start. With no videos or pictures left to show, the
/// chosen gradient shows instead.
class Wallpaper extends StatelessWidget {
  const Wallpaper({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: s.config,
      builder: (context, _) {
        final config = s.config;
        final plain = switch (config.wallpaper) {
          'gradient' => true,
          'video' => config.videos.isEmpty,
          'image' => config.pictures.isEmpty,
          _ => false,
        };
        final colors = plain ? gradients[config.gradient.clamp(0, gradients.length - 1)].$2 : _graphite;
        final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
        return Stack(
          fit: StackFit.expand,
          children: [
            // See-through while an HDR film plays beneath the screen.
            ValueListenableBuilder(
              valueListenable: s.hdrBeneath,
              builder: (context, beneath, gradient) => beneath ? const SizedBox.shrink() : gradient!,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                ),
              ),
            ),
            if (config.wallpaper == 'aerials')
              _aerials(s, config)
            else if (config.wallpaper == 'video' && config.videos.isNotEmpty)
              VideoShow(sources: config.videos, shuffle: config.videoShuffle, loopMinutes: config.videoLoopMinutes)
            else if (config.wallpaper == 'image' && config.pictures.isNotEmpty)
              PictureShow(
                sources: config.pictures,
                every: Duration(minutes: config.pictureMinutes),
                shuffle: config.pictureShuffle,
                cacheWidth: size.width.round(),
              ),
            if (config.dimming > 0) ColoredBox(color: Color.fromRGBO(0, 0, 0, config.dimming)),
          ],
        );
      },
    );
  }
}

/// Apple's aerial films: drawn into the screen, or in HDR beneath it.
Widget _aerials(Services s, Config config) {
  // A new quality or choice of scenes starts over with matching films.
  final key = ValueKey('${config.aerialQuality} ${config.aerialsOff.join(',')}');
  final maxLength = config.aerialMinutes > 0 ? Duration(minutes: config.aerialMinutes) : null;
  Scene? next(Scene? previous) =>
      s.aerials.next(previous, config.aerialQuality, off: config.aerialsOff, useSaved: config.aerialCache);
  void showing(Scene scene) {
    s.caption.value = scene.caption;
    if (config.aerialCache) s.aerials.remember(scene, config.aerialQuality);
  }

  return s.aerials.showsHdr(config.aerialQuality)
      ? HdrScenePlayer(key: key, speed: config.aerialSpeed, maxLength: maxLength, next: next, onShowing: showing)
      : ScenePlayer(key: key, speed: config.aerialSpeed, maxLength: maxLength, next: next, onShowing: showing);
}

/// The pictures [sources] stand for (picture files, and folders standing for
/// every picture in them), each fading into the next after [every], in the
/// order chosen or shuffled. A single picture just stays.
class PictureShow extends StatefulWidget {
  const PictureShow({
    super.key,
    required this.sources,
    required this.every,
    required this.shuffle,
    required this.cacheWidth,
  });

  final List<String> sources;
  final Duration every;
  final bool shuffle;

  /// Pictures are decoded at the screen's width, however large they are.
  final int cacheWidth;

  /// The config changes [sources] in place, so the state compares this.
  String get _choice => '$shuffle ${sources.join('\n')}';

  @override
  State<PictureShow> createState() => _PictureShowState();
}

class _PictureShowState extends State<PictureShow> {
  List<String> _pictures = const [];
  String? _shown;
  String _choice = '';
  Timer? _next;
  final _missing = _Missing();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PictureShow old) {
    super.didUpdateWidget(old);
    if (widget._choice != _choice) {
      _missing.reset();
      _load();
    } else if (old.every != widget.every) {
      _start();
    }
  }

  /// Finds the pictures. One still chosen stays on screen; else the first
  /// new one fades in.
  Future<void> _load() async {
    final choice = _choice = widget._choice;
    final found = await Media.expand(widget.sources, MediaKind.pictures);
    if (!mounted || choice != _choice) return;
    _missing.check(found, widget.sources, _load);
    if (widget.shuffle) found.shuffle();
    setState(() {
      _pictures = found;
      if (!found.contains(_shown)) _shown = found.firstOrNull;
    });
    _start();
  }

  void _start() {
    _next?.cancel();
    if (_pictures.length < 2) return;
    _next = Timer.periodic(
      widget.every,
      (_) => setState(() => _shown = _pictures[(_pictures.indexOf(_shown ?? '') + 1) % _pictures.length]),
    );
  }

  @override
  void dispose() {
    _next?.cancel();
    _missing.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _shown;
    if (path == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: const Duration(seconds: 2),
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: Image.file(File(path), key: ValueKey(path), fit: BoxFit.cover, cacheWidth: widget.cacheWidth),
    );
  }
}

/// The videos [sources] stand for, chosen like [PictureShow]'s pictures,
/// played one after another with a crossfade, in the order chosen or
/// shuffled. A single video loops seamlessly.
class VideoShow extends StatefulWidget {
  const VideoShow({super.key, required this.sources, required this.shuffle, required this.loopMinutes});

  final List<String> sources;
  final bool shuffle;

  /// With several videos, each loops seamlessly this long before the next
  /// fades in; 0 plays each once.
  final int loopMinutes;

  String get _choice => '$shuffle ${sources.join('\n')}';

  @override
  State<VideoShow> createState() => _VideoShowState();
}

class _VideoShowState extends State<VideoShow> {
  List<String> _videos = const [];

  /// Some of them are HDR, so all play beneath the screen.
  bool _hdr = false;

  /// The choice being looked up, and the one [_videos] came from.
  String _choice = '', _found = '';

  /// Shuffled videos still to play this round.
  final _bag = <String>[];
  final _missing = _Missing();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VideoShow old) {
    super.didUpdateWidget(old);
    if (widget._choice != _choice) {
      _missing.reset();
      _load();
    }
  }

  @override
  void dispose() {
    _missing.reset();
    super.dispose();
  }

  Future<void> _load() async {
    final choice = _choice = widget._choice;
    final found = await Media.expand(widget.sources, MediaKind.videos);
    final hdr = (await Future.wait(found.map(Native.isHdr))).any((isHdr) => isHdr);
    if (!mounted || choice != _choice) return;
    _missing.check(found, widget.sources, _load);
    setState(() {
      _videos = found;
      _hdr = hdr;
      _found = choice;
      _bag.clear();
    });
  }

  /// The video after [previous]: the next in order, or the next shuffled one,
  /// never the same twice in a row.
  Future<Scene?> _next(Scene? previous) async {
    final videos = _videos;
    if (videos.isEmpty) return null;
    final String path;
    if (widget.shuffle) {
      if (_bag.isEmpty) {
        _bag.addAll(List.of(videos)..shuffle());
        if (_bag.length > 1 && _bag.last == previous?.uri) _bag.insert(0, _bag.removeLast());
      }
      path = _bag.removeLast();
    } else {
      path = videos[(videos.indexOf(previous?.uri ?? '') + 1) % videos.length];
    }
    return Scene(path, '', file: true, loop: videos.length == 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_videos.isEmpty) return const SizedBox.shrink();
    final loop = widget.loopMinutes > 0;
    final maxLength = loop ? Duration(minutes: widget.loopMinutes) : null;
    return _hdr
        ? HdrScenePlayer(source: _found, next: _next, loop: loop, maxLength: maxLength)
        : ScenePlayer(source: _found, next: _next, loop: loop, maxLength: maxLength);
  }
}

/// Looks again for chosen pictures or videos none of which could be found:
/// just after the TV starts, its storage, and any USB drive, can take a few
/// seconds to be readable, and GTVL starts before them.
class _Missing {
  static const _waits = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 15), Duration(minutes: 1)];
  int _tries = 0;
  Timer? _again;

  /// After a look that [found] these of [sources]: look again with [load]
  /// if none were there, and stop once any are.
  void check(List<String> found, List<String> sources, VoidCallback load) {
    _again?.cancel();
    if (found.isNotEmpty || sources.isEmpty) {
      _tries = 0;
    } else if (_tries < _waits.length) {
      _again = Timer(_waits[_tries++], load);
    }
  }

  void reset() {
    _again?.cancel();
    _tries = 0;
  }
}
