import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'config.dart';
import 'native.dart';

/// The sounds of moving around and pressing OK, from the set Config.sounds
/// names.
///
/// Android plays these itself in apps built from its own views. GTVL draws
/// its own screen, so it asks for them: a move when an arrow key moves focus,
/// a press when OK presses something (Pressable). As in Android, an arrow
/// that moves nothing (at the end of a row) or changes a value (a slider)
/// makes no sound, and neither does holding OK for a menu.
abstract final class Sounds {
  /// The sets, as (value, label): the TV's own sounds, GTVL's test pop, none.
  static const sets = [('android', 'Android'), ('pop', 'Pop'), ('off', 'Off')];

  static final _arrows = {
    LogicalKeyboardKey.arrowUp: 'up',
    LogicalKeyboardKey.arrowDown: 'down',
    LogicalKeyboardKey.arrowLeft: 'left',
    LogicalKeyboardKey.arrowRight: 'right',
  };

  /// Focus moving this soon after an arrow counts as that arrow's move: it
  /// moves while the key is handled, or a frame or two later, which on a slow
  /// TV building a new level can take a while.
  static const _window = Duration(milliseconds: 500);

  static String _set = 'off';
  static final _clock = Stopwatch()..start();

  /// The arrow pressed last, where focus was before it, and when.
  static String? _arrow;
  static FocusNode? _from;
  static Duration _at = Duration.zero;

  /// Plays sounds from the set [config] names, following changes to it.
  static void start(Config config) {
    void use() {
      if (config.sounds == _set) return;
      _set = config.sounds;
      Native.useSounds(_set);
    }

    use();
    config.addListener(use);
    HardwareKeyboard.instance.addHandler(_onKey);
    FocusManager.instance.addListener(_onFocus);
  }

  /// OK pressed something.
  static void press() => _play('press');

  static void _play(String event) {
    if (_set != 'off') Native.sound(event);
  }

  /// Sees every key before the focus system does, and handles none.
  static bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    _arrow = _arrows[event.logicalKey];
    _from = FocusManager.instance.primaryFocus;
    _at = _clock.elapsed;
    return false;
  }

  static void _onFocus() {
    final arrow = _arrow;
    if (arrow == null || FocusManager.instance.primaryFocus == _from) return;
    _arrow = null;
    if (_clock.elapsed - _at < _window) _play(arrow);
  }
}
