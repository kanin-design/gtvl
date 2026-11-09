import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'config.dart';
import 'media.dart';
import 'native.dart';
import 'player.dart';
import 'services.dart';
import 'ui.dart';

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
///
/// The screensaver is the wallpaper, on its own. One that doesn't move (a
/// gradient, a single picture) gives way to aerial films while it shows.
class Wallpaper extends StatelessWidget {
  const Wallpaper({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.config, s.saver, s.filmBeneath]),
      builder: (context, _) {
        final config = s.config;
        final plain = switch (config.wallpaper) {
          'gradient' => true,
          'video' => config.videos.isEmpty,
          'image' => config.pictures.isEmpty,
          _ => false,
        };
        final colors = plain ? gradients[config.gradient.clamp(0, gradients.length - 1)].$2 : _graphite;
        final still =
            plain ||
            config.wallpaper == 'image' &&
                config.pictures.length == 1 &&
                MediaKind.pictures.matches(config.pictures.first);
        final saverFilm = still && s.saver.value;
        final beneath = s.filmBeneath.value;
        final size = MediaQuery.sizeOf(context) * MediaQuery.devicePixelRatioOf(context);
        final pictures = config.wallpaper == 'image' && config.pictures.isNotEmpty
            ? PictureShow(
                sources: config.pictures,
                every: Duration(minutes: config.pictureMinutes),
                shuffle: config.pictureShuffle,
                cacheWidth: size.width.round(),
                blur: config.glassBlur,
                dimming: config.dimming,
              )
            : null;
        final filmShows = beneath && (saverFilm || !still);
        return Stack(
          fit: StackFit.expand,
          children: [
            // Beneath the screen, so under all of this.
            if (still)
              AnimatedSwitcher(
                duration: Look.medium,
                layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
                child: saverFilm ? _aerials(s, config, caption: false) : const SizedBox.shrink(),
              )
            else if (config.wallpaper == 'aerials')
              _aerials(s, config)
            else if (config.wallpaper == 'video')
              VideoShow(sources: config.videos, shuffle: config.videoShuffle, loopMinutes: config.videoLoopMinutes),
            // Fades off a film's first frame. A screensaver's film plays on
            // while it fades back; another is gone already, so it is back at once.
            AnimatedOpacity(
              opacity: filmShows ? 0 : 1,
              duration: filmShows
                  ? const Duration(milliseconds: 1500)
                  : still
                  ? Look.medium
                  : Duration.zero,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
                    ),
                  ),
                  if (still) ?pictures,
                ],
              ),
            ),
            if (!still) ?pictures,
            if (config.dimming > 0) ColoredBox(color: Color.fromRGBO(0, 0, 0, config.dimming)),
          ],
        );
      },
    );
  }
}

/// Apple's aerial films, each saying what it shows, under the clock, with
/// [caption].
Widget _aerials(Services s, Config config, {bool caption = true}) {
  // A new quality or choice of scenes starts over with matching films.
  final key = ValueKey('${config.aerialQuality} ${config.aerialsOff.join(',')}');
  final maxLength = config.aerialMinutes > 0 ? Duration(minutes: config.aerialMinutes) : null;
  Scene? next(Scene? previous) =>
      s.aerials.next(previous, config.aerialQuality, off: config.aerialsOff, useSaved: config.aerialCache);
  void showing(Scene scene) {
    if (caption) s.caption.value = scene.caption;
    if (config.aerialCache) s.aerials.remember(scene, config.aerialQuality);
  }

  return ScenePlayer(
    key: key,
    hdr: s.aerials.showsHdr(config.aerialQuality),
    speed: config.aerialSpeed,
    maxLength: maxLength,
    next: next,
    onShowing: showing,
  );
}

/// The pictures [sources] stand for (picture files, and folders standing for
/// every picture in them), each fading into the next after [every], in the
/// order chosen or shuffled. A single picture just stays.
///
/// The dock's glass shows the picture blurred by [blur] (dp) and dimmed by
/// [dimming] as the screen dims it: one small copy a picture, made as it
/// shows ([BlurredWallpaper]).
class PictureShow extends StatefulWidget {
  const PictureShow({
    super.key,
    required this.sources,
    required this.every,
    required this.shuffle,
    required this.cacheWidth,
    this.blur = 0,
    this.dimming = 0,
  });

  final List<String> sources;
  final Duration every;
  final bool shuffle;

  /// Pictures are decoded at the screen's width, however large they are.
  final int cacheWidth;

  final double blur, dimming;

  /// The config changes [sources] in place, so the state compares this.
  String get _choice => '$shuffle ${sources.join('\n')}';

  /// How long one picture takes to fade into the next.
  static const fade = Duration(seconds: 2);

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
    if (old.blur != widget.blur || old.dimming != widget.dimming) _blurCopy();
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
    _blurCopy();
    _start();
  }

  void _start() {
    _next?.cancel();
    if (_pictures.length < 2) return;
    _next = Timer.periodic(widget.every, (_) {
      setState(() => _shown = _pictures[(_pictures.indexOf(_shown ?? '') + 1) % _pictures.length]);
      _blurCopy();
    });
  }

  /// Copies made so far: only the newest one shows.
  int _copies = 0;

  /// Makes the blurred copy of the picture shown ([BlurredWallpaper]): small,
  /// as it is blurred anyway, covering the screen as the picture does.
  Future<void> _blurCopy() async {
    final copy = ++_copies;
    final path = _shown;
    final sigma = widget.blur;
    if (path == null || sigma <= 0) {
      BlurredWallpaper.show(null);
      return;
    }
    final screen = MediaQuery.sizeOf(context);
    const width = 480.0;
    try {
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes(), targetWidth: 2 * width.round());
      final frame = await codec.getNextFrame();
      codec.dispose();
      final source = frame.image;
      if (!mounted || copy != _copies) {
        source.dispose();
        return;
      }
      final out = Size(width, (width * screen.height / screen.width).roundToDouble());
      final scale = width / screen.width;
      final size = Size(source.width.toDouble(), source.height.toDouble());
      final fitted = applyBoxFit(BoxFit.cover, size, out);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawImageRect(
          source,
          Alignment.center.inscribe(fitted.source, Offset.zero & size),
          Offset.zero & out,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma * scale, sigmaY: sigma * scale, tileMode: TileMode.clamp),
        );
      if (widget.dimming > 0) {
        canvas.drawRect(Offset.zero & out, Paint()..color = Color.fromRGBO(0, 0, 0, widget.dimming));
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(out.width.round(), out.height.round());
      picture.dispose();
      source.dispose();
      if (!mounted || copy != _copies) {
        image.dispose();
        return;
      }
      BlurredWallpaper.show(image);
    } on Exception {
      // Unreadable: the glass tints the picture without blurring it.
      if (mounted && copy == _copies) BlurredWallpaper.show(null);
    }
  }

  @override
  void dispose() {
    _next?.cancel();
    _missing.reset();
    _copies++;
    // After this frame: whatever lays the copy under glass may be going too.
    WidgetsBinding.instance.addPostFrameCallback((_) => BlurredWallpaper.show(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _shown;
    if (path == null) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: PictureShow.fade,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: Image.file(File(path), key: ValueKey(path), fit: BoxFit.cover, cacheWidth: widget.cacheWidth),
    );
  }
}

/// The picture on screen, blurred and dimmed, as PictureShow copies it for
/// the dock's glass: none over a film, a gradient (which blurs to itself),
/// or with blur off.
abstract final class BlurredWallpaper {
  static final image = ValueNotifier<ui.Image?>(null);

  /// Shows [next] in place of the copy before, or none.
  static void show(ui.Image? next) {
    final old = image.value;
    if (identical(old, next)) return;
    image.value = next;
    old?.dispose();
  }
}

/// [BlurredWallpaper]'s copy, as much of it as lies under this box, lined up
/// with the picture on screen; each copy fades into the next as the pictures
/// do. [moving] is how far the box has been moved from its place, as the
/// dock slides: each change lines the copy up again.
class WallpaperBlur extends StatefulWidget {
  const WallpaperBlur({super.key, this.moving = Offset.zero});

  final Offset moving;

  @override
  State<WallpaperBlur> createState() => _WallpaperBlurState();
}

class _WallpaperBlurState extends State<WallpaperBlur> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, duration: PictureShow.fade, value: 1);

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Blur(fade: _fade, screen: MediaQuery.sizeOf(context), moving: widget.moving);
}

class _Blur extends LeafRenderObjectWidget {
  const _Blur({required this.fade, required this.screen, required this.moving});

  final AnimationController fade;
  final Size screen;
  final Offset moving;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBlur(fade, screen, moving);

  @override
  void updateRenderObject(BuildContext context, _RenderBlur render) => render
    ..screen = screen
    ..moving = moving;
}

class _RenderBlur extends RenderBox {
  _RenderBlur(this._fade, this._screen, this._moving);

  final AnimationController _fade;
  Size _screen;
  Offset _moving;

  /// The copy fading out, and the one fading in or shown: clones of
  /// BlurredWallpaper's, held while they are drawn.
  ui.Image? _before, _now;

  set screen(Size value) {
    if (value == _screen) return;
    _screen = value;
    markNeedsPaint();
  }

  set moving(Offset value) {
    if (value == _moving) return;
    _moving = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _now = BlurredWallpaper.image.value?.clone();
    BlurredWallpaper.image.addListener(_changed);
    _fade
      ..addListener(markNeedsPaint)
      ..addStatusListener(_faded);
  }

  @override
  void detach() {
    BlurredWallpaper.image.removeListener(_changed);
    _fade
      ..removeListener(markNeedsPaint)
      ..removeStatusListener(_faded);
    _before?.dispose();
    _now?.dispose();
    _before = _now = null;
    super.detach();
  }

  void _changed() {
    _before?.dispose();
    _before = _now;
    _now = BlurredWallpaper.image.value?.clone();
    _fade.forward(from: 0);
    markNeedsPaint();
  }

  void _faded(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _before?.dispose();
    _before = null;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  // A fade repaints this alone, not the dock over it.
  @override
  bool get isRepaintBoundary => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    final before = _before, now = _now;
    if (before == null && now == null) return;
    // The copy covers the screen, as the picture does: its corner is where the screen's is from here.
    final screen = (offset - localToGlobal(Offset.zero)) & _screen;
    final canvas = context.canvas
      ..save()
      ..clipRect(offset & size);
    void draw(ui.Image image, double opacity) => canvas.drawImageRect(
      image,
      Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
      screen,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(255, 255, 255, opacity),
    );
    // Fading in over the one before, or out to the picture itself.
    if (before != null) draw(before, now == null ? 1 - _fade.value : 1);
    if (now != null) draw(now, _fade.value);
    canvas.restore();
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

  /// Some of them are HDR, so none can fade into another.
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
    return ScenePlayer(source: _found, next: _next, loop: loop, maxLength: maxLength, hdr: _hdr);
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
