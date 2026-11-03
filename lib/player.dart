import 'dart:async';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'native.dart';
import 'services.dart';

/// Plays scenes back to back on the TV's own video layer beneath GTVL's screen
/// (Android's Deck). The next scene loads while one plays, then fades in over
/// it. HDR scenes instead follow without a gap while the screen dips to black,
/// as the TV blends no two HDR films; so do all on a TV that can't fade a video
/// layer.
///
/// One video decodes at a time, except during a scene's last seconds while
/// the next one loads, and none at all while another app is in front, so that
/// app gets the hardware video decoders and the memory.
///
/// The wallpaper's gradient stays over the film until its first frame, then
/// fades off ([Services.filmBeneath]). Drawn, this is only the black of a dip.
///
/// When no scene will open (the TV started before its network was up, say),
/// the gradient stays, and it tries again after a while, and at once when the
/// network comes back.
class ScenePlayer extends StatefulWidget {
  const ScenePlayer({
    super.key,
    required this.next,
    this.source,
    this.onShowing,
    this.speed = 1,
    this.maxLength,
    this.loop = false,
    this.hdr = false,
  });

  /// The scene after [previous]; null [previous] means starting.
  final FutureOr<Scene?> Function(Scene? previous) next;

  /// What [next] chooses from. When it changes, the scene playing goes on
  /// until the next one, from the new choice, can fade in over it.
  final Object? source;

  /// Called when a scene starts showing.
  final ValueChanged<Scene>? onShowing;

  /// Playback speed; below 1 is slower and calmer.
  final double speed;

  /// Moves on after this much of a scene; null plays each scene to its end.
  final Duration? maxLength;

  /// Each scene loops seamlessly until [maxLength] has passed.
  final bool loop;

  /// The scenes are HDR, so they can't fade into one another.
  final bool hdr;

  @override
  State<ScenePlayer> createState() => _ScenePlayerState();
}

class _ScenePlayerState extends State<ScenePlayer> with WidgetsBindingObserver {
  static const _fade = Duration(milliseconds: 1500);
  static const _dip = Duration(milliseconds: 700);
  static const _lead = Duration(seconds: 10);

  /// How late a tick from the deck can tell how long a scene has left.
  static const _tickEvery = Duration(milliseconds: 500);

  /// A film shows: the wallpaper's place turns see-through.
  late final ValueNotifier<bool> _beneath;

  /// Players on screen. The wallpaper turns opaque again only once the last
  /// one has gone, not when another takes its place.
  static int _live = 0;
  StreamSubscription<Object?>? _events;

  /// The scenes handed to the deck, in its order, and the one playing.
  final _scenes = <Scene>[];
  int _index = 0;

  /// Black over the film: around each dip between films.
  bool _covered = false;

  /// The deck holds a film; its first frame is awaited; a next scene is being
  /// chosen, or waited for after several wouldn't open.
  bool _playing = false, _opening = false, _choosing = false;

  /// Scenes fade into one another, rather than dip to black between them.
  bool _fades = false;

  /// Bumped on every new start, so answers from before it are thrown away.
  int _run = 0;

  /// Scenes tried in a row before giving up (offline, unsupported codec).
  static const _attempts = 3;

  /// After giving up, the waits before each new try; past the last, only the
  /// network coming back (or GTVL coming to the front) tries again.
  static const _waits = [Duration(seconds: 5), Duration(seconds: 15), Duration(minutes: 1), Duration(minutes: 5)];

  /// Films that failed in a row, and times given up in a row.
  int _failures = 0, _misses = 0;
  Timer? _retry;

  /// Gave up on films that failed: waiting to try again, after [_stalledAfter].
  bool _stalled = false;
  Scene? _stalledAfter;
  late final ValueNotifier<bool> _online;

  /// How long the scene playing has shown.
  final _shown = Stopwatch();

  Scene? get _current => _index < _scenes.length ? _scenes[_index] : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _beneath = Services.of(context).filmBeneath;
    _online = Services.of(context).status.online..addListener(_onOnline);
    _live++;
    _events = Native.events.where((event) => event['type'] == 'deck').listen(_onEvent);
    if (_inFront) _start();
  }

  @override
  void didUpdateWidget(ScenePlayer old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      final now = _current;
      if (_playing && _fades && !widget.hdr && now != null) {
        _run++;
        _scenes.length = _index + 1;
        _chooseAfter(now, fadeAtOnce: true);
      } else {
        _start(now);
      }
    } else if (_playing && (old.loop != widget.loop || old.speed != widget.speed)) {
      Native.deckAdjust(loop: (_current?.loop ?? false) || widget.loop, speed: widget.speed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _online.removeListener(_onOnline);
    _retry?.cancel();
    _events?.cancel();
    _run++;
    Native.deckStop();
    _live--;
    // After this frame: the tree is locked while it is taken down.
    final beneath = _beneath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_live == 0) beneath.value = false;
    });
    super.dispose();
  }

  /// Nothing plays while another app is in front; coming back starts it.
  static bool get _inFront => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
    _ => true,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_playing) {
          Native.deckResume();
        } else {
          _failures = _misses = 0;
          _start();
        }
      case AppLifecycleState.inactive:
        Native.deckPause();
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        // Another app gets the decoder and the memory.
        _run++;
        _retry?.cancel();
        _stalled = false;
        _playing = _opening = false;
        Native.deckStop();
        _beneath.value = false;
        if (mounted) setState(() => _covered = false);
    }
  }

  /// Starts over with the scene after [after], in black if one was showing.
  Future<void> _start([Scene? after]) async {
    final run = ++_run;
    if (mounted && _beneath.value) setState(() => _covered = true);
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
    _retry?.cancel();
    _choosing = false;
    _playing = _opening = true;
    final fades = await Native.deckPlay(scene.uri, loop: scene.loop || widget.loop, speed: widget.speed);
    if (run == _run) _fades = fades && !widget.hdr;
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (!_playing) return;
    switch (event['what']) {
      case 'frame':
        _failures = _misses = 0;
        _stalled = false;
        if (_opening) {
          _opening = false;
          _beneath.value = true;
          _reveal();
        }
      case 'next':
        _failures = _misses = 0;
        _index = event['index'] is int ? event['index']! as int : _index + 1;
        _reveal();
      case 'position':
        if (event case {'position': final int position, 'duration': final int duration}) _tick(position, duration);
      case 'missed':
        debugPrint('Scene "${_scenes.last.caption}" failed: ${event['message']}');
        _missedNext(_scenes.removeLast());
      case 'ended':
        // Nothing came next in time: start over with the scene after this one.
        _start(_current);
      case 'error':
        debugPrint('Scene "${_current?.caption}" failed: ${event['message']}');
        if (++_failures < _attempts) {
          _start(_current);
        } else {
          _giveUp(retry: true);
        }
    }
  }

  /// The next scene wouldn't open, so the one playing goes on over and over.
  /// The one after [missed] gets its turn, or after a few, one after a wait.
  void _missedNext(Scene missed) {
    if (++_failures < _attempts) {
      _chooseAfter(missed);
      return;
    }
    _failures = 0;
    _choosing = true;
    final run = _run;
    _retry?.cancel();
    _retry = Timer(_waits[_misses.clamp(0, _waits.length - 1)], () {
      if (run == _run) _choosing = false;
    });
    _misses++;
  }

  /// Nothing will play (offline, no scenes chosen, films this TV can't
  /// decode): the gradient shows. With [retry] (films failed), a new try
  /// comes after a wait, or at once when the network comes back.
  void _giveUp({bool retry = false}) {
    final after = _current;
    _run++;
    _playing = _opening = false;
    Native.deckStop();
    _beneath.value = false;
    setState(() => _covered = false);
    _retry?.cancel();
    _stalled = retry;
    _stalledAfter = after;
    if (!retry || _misses >= _waits.length) return;
    final run = _run;
    _retry = Timer(_waits[_misses++], () {
      if (run == _run && _stalled) _tryAgain();
    });
  }

  /// The network is back: a stalled player tries again at once.
  void _onOnline() {
    if (!_online.value || !_stalled || !_inFront) return;
    _retry?.cancel();
    _tryAgain();
  }

  void _tryAgain() {
    _stalled = false;
    _failures = 0;
    _start(_stalledAfter);
  }

  /// The film playing shows: lift any black once its first frames are up.
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

  /// Chooses the scene after [after] and hands it to the deck ahead of time.
  void _chooseAfter(Scene after, {bool fadeAtOnce = false}) {
    _choosing = true;
    final run = _run;
    Future.value(widget.next(after)).then((next) {
      if (run != _run) return;
      _choosing = false;
      if (next == null) return;
      _scenes.add(next);
      Native.deckQueue(next.uri, loop: next.loop || widget.loop, blend: _fades);
      if (fadeAtOnce) Native.deckSkip(_fade);
    });
  }

  /// Loads the next scene ahead of time, then fades to it or dips to black
  /// before the change, and cuts a scene short when its time is up.
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
    if (left <= _lead && !queued && !_choosing) _chooseAfter(scene);
    if (!queued) return;
    if (_fades) {
      if (left <= _fade + _tickEvery) Native.deckSkip(_fade);
    } else {
      if (!_covered && left <= _dip + const Duration(milliseconds: 300)) setState(() => _covered = true);
      if (cutShort && left <= Duration.zero) Native.deckSkip();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _covered ? 1 : 0,
    duration: _dip,
    curve: Curves.easeInOut,
    child: const ColoredBox(color: Color(0xFF000000)),
  );
}
