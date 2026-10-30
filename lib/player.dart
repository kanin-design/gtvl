import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'aerials.dart';
import 'services.dart';

/// Plays scenes back to back with a crossfade, drawn into GTVL's screen.
/// HDR scenes play beneath it instead (see HdrScenePlayer).
///
/// One video decodes at a time, except during a scene's last seconds while
/// the next one buffers, and none at all while another app is in front, so
/// that app gets the hardware video decoders and the memory.
///
/// When no scene will open (the TV started before its network was up, say),
/// it tries again after a while, and at once when the network comes back.
class ScenePlayer extends StatefulWidget {
  const ScenePlayer({
    super.key,
    required this.next,
    this.source,
    this.onShowing,
    this.speed = 1,
    this.maxLength,
    this.loop = false,
  });

  /// The scene after [previous]; null [previous] means starting.
  final FutureOr<Scene?> Function(Scene? previous) next;

  /// What [next] chooses from. When it changes, the scene playing goes on
  /// until the next one, from the new choice, can fade in over it.
  final Object? source;

  /// Called when a scene starts fading in.
  final ValueChanged<Scene>? onShowing;

  /// Playback speed; below 1 is slower and calmer.
  final double speed;

  /// Moves on after this much of a scene; null plays each scene to its end.
  final Duration? maxLength;

  /// Each scene loops seamlessly until [maxLength] has passed.
  final bool loop;

  @override
  State<ScenePlayer> createState() => _ScenePlayerState();
}

class _Layer {
  _Layer(this.scene, this.video);

  final Scene scene;
  final VideoPlayerController video;
  bool shown = false;

  /// Runs from when the scene starts fading in.
  final played = Stopwatch();
}

class _ScenePlayerState extends State<ScenePlayer> with WidgetsBindingObserver {
  static const _fade = Duration(milliseconds: 1500);
  static const _lead = Duration(seconds: 10);

  /// Scenes tried in a row before giving up (offline, unsupported codec).
  static const _attempts = 3;

  /// After giving up, the waits before each new try; past the last, only the
  /// network coming back (or GTVL coming to the front) tries again.
  static const _waits = [Duration(seconds: 5), Duration(seconds: 15), Duration(minutes: 1), Duration(minutes: 5)];

  _Layer? _out, _now, _next;
  bool _preparing = false;
  bool _fading = false;

  /// The last [_prepare] tried [_attempts] scenes and none would open.
  bool _gaveUp = false;

  /// Nothing would open: waiting to try again, after [_stalledAfter].
  bool _stalled = false;
  Scene? _stalledAfter;
  int _misses = 0;
  Timer? _retry;
  late final ValueNotifier<bool> _online;

  /// Bumped on every stop, so async work from before it is thrown away.
  int _run = 0;
  Timer? _fadeDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _online = Services.of(context).status.online..addListener(_onOnline);
    if (_inFront) _start();
  }

  /// Nothing plays while another app is in front; coming back starts it.
  static bool get _inFront => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
    _ => true,
  };

  @override
  void didUpdateWidget(ScenePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speed != widget.speed) _now?.video.setPlaybackSpeed(widget.speed);
    if (oldWidget.loop != widget.loop) _now?.video.setLooping(widget.loop || _now!.scene.loop);
    if (oldWidget.source != widget.source) _switch();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _online.removeListener(_onOnline);
    _release();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final now = _now;
        if (now == null) {
          _start();
        } else if (now.video.value.hasError) {
          _start(now.scene);
        } else {
          now.video.play();
        }
      case AppLifecycleState.inactive:
        _now?.video.pause();
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _release();
        if (mounted) setState(() {});
    }
  }

  void _start([Scene? after]) {
    final run = _run;
    _prepare(after).then((layer) {
      if (run != _run) return;
      if (layer != null) {
        _stalled = false;
        _misses = 0;
        _show(layer);
      } else if (_gaveUp) {
        _stall(after);
      }
    });
  }

  /// No scene would open: try again after a wait that grows with each miss.
  void _stall(Scene? after) {
    _stalled = true;
    _stalledAfter = after;
    _retry?.cancel();
    if (_misses >= _waits.length) return;
    final run = _run;
    _retry = Timer(_waits[_misses++], () {
      if (run == _run && _stalled) _start(after);
    });
  }

  /// The network is back: a stalled player tries again at once.
  void _onOnline() {
    if (!_online.value || !_stalled || !_inFront) return;
    _retry?.cancel();
    _start(_stalledAfter);
  }

  /// A new choice of scenes: drops the next scene, if one was ready, and
  /// fades in the one after the current scene by the new choice.
  void _switch() {
    _run++;
    _preparing = false;
    _next?.video.dispose();
    _next = null;
    if (_inFront) _start(_now?.scene);
  }

  void _release() {
    _run++;
    _fadeDone?.cancel();
    _retry?.cancel();
    _stalled = false;
    _misses = 0;
    for (final layer in {_out, _now, _next}) {
      layer?.video.removeListener(_tick);
      layer?.video.dispose();
    }
    _out = _now = _next = null;
    _preparing = _fading = false;
  }

  /// Opens the next scene without playing it, skipping any that fail to load.
  Future<_Layer?> _prepare(Scene? previous) async {
    if (_preparing) return null;
    _preparing = true;
    _gaveUp = false;
    final run = _run;
    try {
      for (var attempt = 0; attempt < _attempts; attempt++) {
        final scene = await widget.next(previous);
        if (scene == null || run != _run) return null;
        previous = scene;
        // A wallpaper must never take audio focus from what else is playing.
        final options = VideoPlayerOptions(mixWithOthers: true);
        final video = scene.file
            ? VideoPlayerController.file(File(scene.uri), videoPlayerOptions: options)
            : VideoPlayerController.networkUrl(Uri.parse(scene.uri), videoPlayerOptions: options);
        try {
          await video.initialize();
          await video.setVolume(0);
          if (widget.speed != 1) await video.setPlaybackSpeed(widget.speed);
          if (scene.loop || widget.loop) await video.setLooping(true);
          if (run != _run || !mounted) {
            await video.dispose();
            return null;
          }
          return _Layer(scene, video);
        } on Object catch (e) {
          debugPrint('Scene "${scene.caption}" failed: $e');
          await video.dispose();
        }
      }
      _gaveUp = run == _run;
      return null;
    } finally {
      if (run == _run) _preparing = false;
    }
  }

  /// Fades [layer] in over the current scene, then releases the old one.
  void _show(_Layer layer) {
    // A new choice can arrive mid-fade: the scene fading out goes at once.
    final gone = _out;
    if (gone != null) {
      gone.video.removeListener(_tick);
      gone.video.dispose();
    }
    final old = _now;
    _out = old;
    _now = layer;
    _next = null;
    _fading = true;
    layer.played.start();
    layer.video
      ..addListener(_tick)
      ..play();
    widget.onShowing?.call(layer.scene);
    setState(() {});
    // Shown on the next frame, so the fade starts from transparent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _now == layer) setState(() => layer.shown = true);
    });
    _fadeDone?.cancel();
    _fadeDone = Timer(_fade, () {
      old?.video.removeListener(_tick);
      old?.video.dispose();
      if (_out == old) _out = null;
      _fading = false;
      if (mounted) setState(() {});
    });
  }

  void _tick() {
    final now = _now;
    if (now == null) return;
    final value = now.video.value;
    if (value.hasError) {
      _broke(now);
      return;
    }
    if (_fading || now.scene.loop || !value.isInitialized || value.duration == Duration.zero) return;
    final max = widget.maxLength;
    // A looping scene runs out its time; any other ends with its video, or sooner.
    final left = widget.loop && max != null
        ? max - now.played.elapsed
        : (max != null && max < value.duration ? max : value.duration) - value.position;

    if (left <= _lead && _next == null && !_preparing) {
      final run = _run;
      _prepare(now.scene).then((next) {
        if (run != _run || _now != now) {
          next?.video.dispose();
        } else if (next == null) {
          // Nothing else would load: keep this one going.
          now.video.setLooping(true);
          if (now.video.value.isCompleted) now.video.play();
        } else {
          _next = next;
          // Ready only after this one ended or broke off, which ticks no more: change now.
          if (now.video.value.isCompleted || now.video.value.hasError) _show(next);
        }
      });
    }
    final next = _next;
    if (next != null && (left <= _fade || value.isCompleted)) _show(next);
  }

  /// The scene playing broke off (the network dropped), and ticks no more:
  /// the next one fades in as soon as it is ready, or one is looked for.
  void _broke(_Layer now) {
    final next = _next;
    if (next != null) {
      _show(next);
    } else if (!_preparing) {
      _start(now.scene);
    }
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Stack(
      fit: StackFit.expand,
      children: [
        for (final layer in [?_out, ?_now])
          AnimatedOpacity(
            key: ObjectKey(layer),
            opacity: layer.shown ? 1 : 0,
            duration: _fade,
            curve: Curves.easeInOut,
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox.fromSize(size: layer.video.value.size, child: VideoPlayer(layer.video)),
            ),
          ),
      ],
    ),
  );
}
