import 'dart:async';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'native.dart';
import 'services.dart';

/// Plays HDR scenes on the TV's own video layer beneath GTVL's screen
/// (Android's HdrDeck), where Dolby Vision shows right and menus over it
/// don't flicker. The next scene loads while one plays and follows it
/// without a gap; the screen dips to black between them, as the TV blends no
/// two HDR films. Takes the same choices as ScenePlayer.
///
/// Drawn, it is a black cover that lifts once a film shows; the wallpaper
/// leaves its place see-through meanwhile ([Services.hdrBeneath]).
class HdrScenePlayer extends StatefulWidget {
  const HdrScenePlayer({
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

  /// What [next] chooses from; a new choice starts over with it.
  final Object? source;

  /// Called when a scene starts showing.
  final ValueChanged<Scene>? onShowing;
  final double speed;

  /// Moves on after this much of a scene; null plays each to its end.
  final Duration? maxLength;

  /// Each scene loops until [maxLength] has passed.
  final bool loop;

  @override
  State<HdrScenePlayer> createState() => _HdrScenePlayerState();
}

class _HdrScenePlayerState extends State<HdrScenePlayer> with WidgetsBindingObserver {
  static const _dip = Duration(milliseconds: 700);
  static const _lead = Duration(seconds: 10);

  /// The wallpaper's place see-through, for the film beneath it.
  late final ValueNotifier<bool> _beneath;

  /// HDR players on screen. The wallpaper turns opaque again only once the
  /// last one has gone, not when another takes its place.
  static int _live = 0;
  StreamSubscription<Object?>? _events;

  /// The scenes handed to the deck, in its order, and the one playing.
  final _scenes = <Scene>[];
  int _index = 0;

  /// Black over the film: until it shows, and around each change of film.
  bool _covered = true;

  /// The deck holds a film; a next scene is being chosen.
  bool _playing = false, _choosing = false;

  /// Bumped on every new start, so answers from before it are thrown away.
  int _run = 0;

  /// Films that failed in a row; after a few, the gradient shows instead
  /// until GTVL next comes to the front.
  int _failures = 0;
  static const _attempts = 3;

  /// How long the scene playing has shown.
  final _shown = Stopwatch();

  Scene? get _current => _index < _scenes.length ? _scenes[_index] : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _beneath = Services.of(context).hdrBeneath;
    _live++;
    _events = Native.events.where((event) => event['type'] == 'hdr').listen(_onEvent);
    // The wallpaper's place turns see-through after this frame, not during it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _beneath.value = true;
    });
    if (_inFront) _start();
  }

  @override
  void didUpdateWidget(HdrScenePlayer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _start(_current);
    } else if (_playing && (old.loop != widget.loop || old.speed != widget.speed)) {
      Native.hdrAdjust(loop: (_current?.loop ?? false) || widget.loop, speed: widget.speed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _run++;
    Native.hdrStop();
    _live--;
    // After this frame: the tree is locked while it is taken down.
    final beneath = _beneath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_live == 0) beneath.value = false;
    });
    super.dispose();
  }

  static bool get _inFront => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
    _ => true,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_playing) {
          Native.hdrResume();
        } else {
          _failures = 0;
          _start();
        }
      case AppLifecycleState.inactive:
        Native.hdrPause();
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        // Another app gets the decoder and the memory.
        _run++;
        _playing = false;
        Native.hdrStop();
        if (mounted) setState(() => _covered = true);
    }
  }

  /// Starts over with the scene after [after], in black until it shows.
  Future<void> _start([Scene? after]) async {
    final run = ++_run;
    if (mounted) setState(() => _covered = true);
    final scene = await widget.next(after);
    if (run != _run || !mounted) return;
    if (scene == null) {
      _giveUp();
      return;
    }
    _scenes
      ..clear()
      ..add(scene);
    _index = 0;
    _choosing = false;
    _playing = true;
    _beneath.value = true; // again, after giving up
    await Native.hdrPlay(scene.uri, loop: scene.loop || widget.loop, speed: widget.speed);
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (!_playing) return;
    switch (event['what']) {
      case 'frame':
        _failures = 0;
        if (_covered) _reveal();
      case 'next':
        _failures = 0;
        _index = event['index'] is int ? event['index']! as int : _index + 1;
        _reveal();
      case 'position':
        if (event case {'position': final int position, 'duration': final int duration}) _tick(position, duration);
      case 'ended':
        // Nothing came next in time: start over with the scene after this one.
        _start(_current);
      case 'error':
        debugPrint('HDR scene "${_current?.caption}" failed: ${event['message']}');
        if (++_failures < _attempts) {
          _start(_current);
        } else {
          _giveUp();
        }
    }
  }

  /// Nothing will play (offline, no scenes chosen, films this TV can't
  /// decode): the gradient shows until GTVL next comes to the front.
  void _giveUp() {
    _run++;
    _playing = false;
    Native.hdrStop();
    _beneath.value = false;
    setState(() => _covered = false);
  }

  /// The film playing shows: lift the black once its first frames are up.
  void _reveal() {
    final scene = _current;
    if (scene == null) return;
    _shown
      ..reset()
      ..start();
    widget.onShowing?.call(scene);
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _covered = false);
    });
  }

  /// Chooses and queues the next scene ahead of time, dips to black before
  /// the change, and cuts a scene short when its time is up.
  void _tick(int position, int duration) {
    final scene = _current;
    if (scene == null || scene.loop || duration <= 0) return;
    final max = widget.maxLength;
    final length = Duration(milliseconds: duration);
    final cutShort = max != null && (widget.loop || max < length);
    final left = widget.loop && max != null
        ? max - _shown.elapsed
        : (max != null && max < length ? max : length) - Duration(milliseconds: position);
    final queued = _scenes.length > _index + 1;
    if (left <= _lead && !queued && !_choosing) {
      _choosing = true;
      final run = _run;
      Future.value(widget.next(scene)).then((next) {
        if (run != _run) return;
        _choosing = false;
        if (next == null) return;
        _scenes.add(next);
        Native.hdrQueue(next.uri);
      });
    }
    if (queued && !_covered && left <= _dip + const Duration(milliseconds: 300)) setState(() => _covered = true);
    if (queued && cutShort && left <= Duration.zero) Native.hdrSkip();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _covered ? 1 : 0,
    duration: _dip,
    curve: Curves.easeInOut,
    child: const ColoredBox(color: Color(0xFF000000)),
  );
}
