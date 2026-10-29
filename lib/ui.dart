import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The few values the whole UI shares.
abstract final class Look {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const ease = Curves.easeOutCubic;

  static const white = Color(0xFFFFFFFF);
  static const dim = Color(0x99FFFFFF);
  static const hairline = Color(0x1FFFFFFF);
  static const focusFill = Color(0x26FFFFFF);
  static const danger = Color(0xFFFF6B6B);
  static const shadow = [Shadow(color: Color(0x8C000000), blurRadius: 8, offset: Offset(0, 2))];

  /// The app's default text style; every other style takes Inter from it.
  static const body = TextStyle(
    fontFamily: 'Inter',
    fontSize: 15,
    color: Color(0xF2FFFFFF),
    decoration: TextDecoration.none,
  );
  static const value = TextStyle(fontSize: 14, color: dim);
  static const small = TextStyle(fontSize: 12, color: dim, height: 1.3);
  static const label = TextStyle(fontSize: 13, color: white, fontWeight: FontWeight.w500, shadows: shadow);
  static const title = TextStyle(fontSize: 22, color: white, fontWeight: FontWeight.w600);
  static const clock = TextStyle(fontSize: 22, color: white, fontWeight: FontWeight.w600, shadows: shadow);
  static const caption = TextStyle(fontSize: 12, color: Color(0xCCFFFFFF), shadows: shadow);
}

final _activateKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};

/// Anything the remote can focus and press.
///
/// OK presses on key-down. With [onLongPress], holding OK for a moment (or
/// the Menu key) long-presses instead, and a short press fires on key-up.
/// Repeats and key-ups never press anything, so the OK still held from
/// opening a menu cannot choose an item in it.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onPressed,
    this.onLongPress,
    this.onKey,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// Sees every key first, e.g. arrows while something is being moved.
  final KeyEventResult Function(KeyEvent event)? onKey;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  static const _holdTime = Duration(milliseconds: 450);

  bool _focused = false;
  Timer? _hold;

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final custom = widget.onKey?.call(event) ?? KeyEventResult.ignored;
    if (custom != KeyEventResult.ignored) return custom;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.contextMenu && widget.onLongPress != null) {
      if (event is KeyDownEvent) widget.onLongPress!();
      return KeyEventResult.handled;
    }
    if (!_activateKeys.contains(key)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (widget.onLongPress == null) {
        widget.onPressed?.call();
      } else {
        _hold = Timer(_holdTime, () {
          _hold = null;
          widget.onLongPress!();
        });
      }
    } else if (event is KeyRepeatEvent && _hold != null) {
      // A held key starts repeating: that is a long press, even before the timer.
      _hold!.cancel();
      _hold = null;
      widget.onLongPress!();
    } else if (event is KeyUpEvent && _hold != null) {
      _hold!.cancel();
      _hold = null;
      widget.onPressed?.call();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: widget.autofocus,
    onKeyEvent: _onKey,
    onFocusChange: (focused) {
      if (!focused) {
        _hold?.cancel();
        _hold = null;
      }
      setState(() => _focused = focused);
      widget.onFocusChange?.call(focused);
    },
    child: widget.builder(context, _focused),
  );
}

/// Moves focus like the default policy, then scrolls just enough to keep the
/// focused item a margin away from the edge, smoothly.
final smoothTraversal = ReadingOrderTraversalPolicy(
  requestFocusCallback: (node, {alignment, alignmentPolicy, curve, duration}) {
    node.requestFocus();
    final context = node.context;
    if (context != null) reveal(context);
  },
);

/// Keeps Left and Right inside a row at its ends. With nothing beside the
/// focused item, Flutter looks in other rows, even ones scrolled out of sight.
KeyEventResult rowEnd(KeyEvent event, {required bool first, required bool last}) => switch (event.logicalKey) {
  LogicalKeyboardKey.arrowLeft when first => KeyEventResult.handled,
  LogicalKeyboardKey.arrowRight when last => KeyEventResult.handled,
  _ => KeyEventResult.ignored,
};

/// Scrolls the nearest scrollable so [context] is fully in view with a margin.
/// When the scrollable ends less than [endZone] further on, to the very end
/// instead, so what follows the last row (a note) shows too.
void reveal(BuildContext context, {double margin = 28, double endZone = 0}) {
  final box = context.findRenderObject();
  final position = Scrollable.maybeOf(context)?.position;
  if (box == null || position == null) return;
  final viewport = RenderAbstractViewport.of(box);
  final atStart = viewport.getOffsetToReveal(box, 0).offset - margin;
  final atEnd = viewport.getOffsetToReveal(box, 1).offset + margin;
  final target = position.maxScrollExtent - atEnd < endZone
      ? position.maxScrollExtent
      : position.pixels > atStart
      ? atStart
      : (position.pixels < atEnd ? atEnd : null);
  if (target == null) return;
  position.animateTo(
    target.clamp(position.minScrollExtent, position.maxScrollExtent),
    duration: Look.medium,
    curve: Look.ease,
  );
}

/// Frosted glass: blurs what is behind it by [sigma] (0 for none) and tints it.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.tint = const Color(0x14FFFFFF),
    this.sigma = 24,
    this.radius = BorderRadius.zero,
    this.border,
  });

  final Widget child;
  final Color tint;
  final double sigma;
  final BorderRadius radius;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final body = DecoratedBox(
      decoration: BoxDecoration(color: tint, borderRadius: radius, border: border),
      child: child,
    );
    // The same widgets with blur off: swapping them would rebuild everything
    // inside, dock apps and their focus included.
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        enabled: sigma > 0,
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: body,
      ),
    );
  }
}

/// A small dot on an icon's corner: something waits there, such as an update.
class Badge extends StatelessWidget {
  const Badge({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 7,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Look.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0x8C000000), blurRadius: 4)],
      ),
    ),
  );
}

/// A one-pixel line, optionally starting [indent] in from the left.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: const SizedBox(
      height: 1,
      width: double.infinity,
      child: ColoredBox(color: Look.hairline),
    ),
  );
}

/// An on/off switch, in white and grey: no colour to compete with the wallpaper.
class Toggle extends StatelessWidget {
  const Toggle({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Look.fast,
    width: 36,
    height: 21,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: on ? const Color(0xE6FFFFFF) : const Color(0x33FFFFFF),
      borderRadius: BorderRadius.circular(11),
    ),
    child: AnimatedAlign(
      duration: Look.fast,
      curve: Look.ease,
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      child: SizedBox.square(
        dimension: 17,
        child: DecoratedBox(
          decoration: BoxDecoration(color: on ? const Color(0xFF1C1C1E) : Look.white, shape: BoxShape.circle),
        ),
      ),
    ),
  );
}

/// A see-through route for menus and panels: fades in, sliding from [from].
PageRouteBuilder<R> overlayRoute<R>(WidgetBuilder builder, {Offset from = Offset.zero}) => PageRouteBuilder<R>(
  opaque: false,
  barrierColor: const Color(0x33000000),
  transitionDuration: Look.medium,
  reverseTransitionDuration: Look.fast,
  pageBuilder: (context, _, _) => builder(context),
  transitionsBuilder: (context, animation, _, child) {
    final curved = CurvedAnimation(parent: animation, curve: Look.ease);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: from, end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  },
);
