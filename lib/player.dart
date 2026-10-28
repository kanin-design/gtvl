import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'aerials.dart';

/// Plays scenes back to back with a crossfade.
///
/// One video decodes at a time, except during a scene's last seconds while
/// the next one buffers, and none at all while another app is in front, so
/// that app gets the hardware video decoders and the memory.
class ScenePlayer extends StatefulWidget {
  const ScenePlayer({super.key, required this.next, this.onShowing});

  /// The scene after [previous]; null [previous] means starting.
  final Scene? Function(Scene? previous) next;

  /// Called when a scene starts fading in.
  final ValueChanged<Scene>? onShowing;

  @override
  State<ScenePlayer> createState() => _ScenePlayerState();
}

class _Layer {
  _Layer(this.scene, this.video);

  final Scene scene;
  final VideoPlayerController video;
  bool shown = false;
}

class _ScenePlayerState extends State<ScenePlayer> with WidgetsBindingObserver {
  static const _fade = Duration(milliseconds: 1500);
  static const _lead = Duration(seconds: 10);

  /// Scenes tried in a row before giving up (offline, unsupported codec).
  static const _attempts = 3;

  _Layer? _out, _now, _next;
  bool _preparing = false;
  bool _fading = false;

  /// Bumped on every stop, so async work from before it is thrown away.
  int _run = 0;
  Timer? _fadeDone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_now == null) {
          _start();
        } else {
          _now!.video.play();
        }
      case AppLifecycleState.inactive:
        _now?.video.pause();
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        _release();
        if (mounted) setState(() {});
    }
  }

  void _start() {
    final run = _run;
    _prepare(null).then((layer) {
      if (layer != null && run == _run) _show(layer);
    });
  }

  void _release() {
    _run++;
    _fadeDone?.cancel();
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
    final run = _run;
    try {
      for (var attempt = 0; attempt < _attempts; attempt++) {
        final scene = widget.next(previous);
        if (scene == null) return null;
        previous = scene;
        // A wallpaper must never take audio focus from what else is playing.
        final options = VideoPlayerOptions(mixWithOthers: true);
        final video = scene.file
            ? VideoPlayerController.file(File(scene.uri), videoPlayerOptions: options)
            : VideoPlayerController.networkUrl(Uri.parse(scene.uri), videoPlayerOptions: options);
        try {
          await video.initialize();
          await video.setVolume(0);
          if (scene.loop) await video.setLooping(true);
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
      return null;
    } finally {
      if (run == _run) _preparing = false;
    }
  }

  /// Fades [layer] in over the current scene, then releases the old one.
  void _show(_Layer layer) {
    final old = _now;
    _out = old;
    _now = layer;
    _next = null;
    _fading = true;
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
    if (now == null || _fading || now.scene.loop) return;
    final value = now.video.value;
    if (!value.isInitialized || value.duration == Duration.zero) return;
    final left = value.duration - value.position;

    if (left <= _lead && _next == null && !_preparing) {
      final run = _run;
      _prepare(now.scene).then((next) {
        if (run != _run || _now != now) {
          next?.video.dispose();
        } else if (next == null) {
          now.video.setLooping(true); // nothing else would load: keep this one going
        } else {
          _next = next;
        }
      });
    }
    final next = _next;
    if (next != null && (left <= _fade || value.isCompleted)) _show(next);
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
