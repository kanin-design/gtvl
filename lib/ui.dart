import 'dart:async';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The few values the whole UI shares.
abstract final class Look {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const ease = Curves.easeOutCubic;

  static const white = Color(0xFFFFFFFF);
  static const dim = Color(0xB3FFFFFF);
  static const hairline = Color(0x1FFFFFFF);

  /// A focused row: a light fill with a finer, brighter edge, to see from
  /// across the room.
  static const focusFill = Color(0x47FFFFFF);
  static const focusEdge = Color(0x38FFFFFF);
  static const danger = Color(0xFFFF6B6B);
  static const shadow = [Shadow(color: Color(0x8C000000), blurRadius: 8, offset: Offset(0, 2))];

  /// The app's default text style; every other style takes Inter from it.
  static const body = TextStyle(
    fontFamily: 'Inter',
    fontSize: 15,
    color: Color(0xF2FFFFFF),
    decoration: TextDecoration.none,
  );
  static const value = TextStyle(fontSize: 15, color: dim);
  static const small = TextStyle(fontSize: 13, color: dim, height: 1.35);
  static const label = TextStyle(fontSize: 13, color: white, fontWeight: FontWeight.w500, shadows: shadow);
  static const title = TextStyle(fontSize: 22, color: white, fontWeight: FontWeight.w600);

  /// Digits that keep their width, so the time and percentages don't jiggle.
  static const figures = [FontFeature.tabularFigures()];
  static const clock = TextStyle(
    fontSize: 22,
    color: white,
    fontWeight: FontWeight.w600,
    shadows: shadow,
    fontFeatures: figures,
  );
  static const caption = TextStyle(fontSize: 13, color: Color(0xCCFFFFFF), shadows: shadow);
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
    this.dip = false,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// Sees every key first, e.g. arrows while something is being moved.
  final KeyEventResult Function(KeyEvent event)? onKey;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Sinks a little while OK is down, so a press shows at once.
  final bool dip;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  static const _holdTime = Duration(milliseconds: 450);

  bool _focused = false, _down = false;
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
      _sink(true);
      if (widget.onLongPress == null) {
        widget.onPressed?.call();
      } else {
        _hold = Timer(_holdTime, () {
          _hold = null;
          _sink(false);
          widget.onLongPress!();
        });
      }
    } else if (event is KeyRepeatEvent && _hold != null) {
      // A held key starts repeating: that is a long press, even before the timer.
      _hold!.cancel();
      _hold = null;
      _sink(false);
      widget.onLongPress!();
    } else if (event is KeyUpEvent) {
      _sink(false);
      if (_hold != null) {
        _hold!.cancel();
        _hold = null;
        widget.onPressed?.call();
      }
    }
    return KeyEventResult.handled;
  }

  void _sink(bool down) {
    if (widget.dip && _down != down && mounted) setState(() => _down = down);
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
        _down = false;
      }
      setState(() => _focused = focused);
      widget.onFocusChange?.call(focused);
    },
    child: widget.dip
        ? AnimatedScale(
            scale: _down ? 0.96 : 1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: widget.builder(context, _focused),
          )
        : widget.builder(context, _focused),
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
/// With [rim], light catches its edge, brightest at the top left, and its
/// tint is a touch lighter at the top: a pane rather than a flat plate.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.tint = const Color(0x14FFFFFF),
    this.sigma = 24,
    this.radius = BorderRadius.zero,
    this.border,
    this.rim = false,
  });

  final Widget child;
  final Color tint;
  final double sigma;
  final BorderRadius radius;
  final BoxBorder? border;
  final bool rim;

  @override
  Widget build(BuildContext context) {
    final Widget body = rim
        ? CustomPaint(
            foregroundPainter: _Rim(radius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                border: border,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color.lerp(tint, const Color(0xFFFFFFFF), 0.05)!, tint],
                ),
              ),
              child: child,
            ),
          )
        : DecoratedBox(
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

/// A one-pixel edge of light around glass, from bright at the top left to
/// faint at the bottom right.
class _Rim extends CustomPainter {
  _Rim(this.radius);

  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0x59FFFFFF), Color(0x1AFFFFFF), Color(0x0DFFFFFF)],
        stops: [0, 0.45, 1],
      ).createShader(rect);
    canvas.drawRRect(radius.toRRect(rect.deflate(0.5)), paint);
  }

  @override
  bool shouldRepaint(_Rim old) => old.radius != radius;
}

/// A short line on a small glass pill, for hints and notices over the home
/// screen. Never focused.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Glass(
    tint: const Color(0xA61C1C1E),
    sigma: 12,
    radius: BorderRadius.circular(18),
    rim: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: Look.label.copyWith(shadows: const [])),
    ),
  );
}

/// A sentence or two that never ends on a lone word: when the last line
/// would hold just one, the lines narrow until a second word joins it.
class Prose extends StatelessWidget {
  const Prose(this.text, {super.key, required this.style, this.textAlign = TextAlign.start});

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  /// Widths already worked out, by text, style and room: rows rebuild with
  /// every move of focus, and working one out takes some twenty layouts.
  static final _widths = <(String, TextStyle, TextAlign, double), double?>{};

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      var effective = DefaultTextStyle.of(context).style.merge(style);
      if (MediaQuery.boldTextOf(context)) effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
      final room = constraints.maxWidth;
      final key = (text, effective, textAlign, room);
      if (_widths.length > 200) _widths.clear();
      final width = _widths.containsKey(key) ? _widths[key] : _widths[key] = _width(context, effective, room);
      final child = Text(text, style: style, textAlign: textAlign);
      if (width == null) return child;
      // The text wraps at [width]; the box still takes the room it's given.
      final spare = room - width;
      return Padding(
        padding: textAlign == TextAlign.center
            ? EdgeInsets.symmetric(horizontal: spare / 2)
            : EdgeInsetsDirectional.only(end: spare),
        child: child,
      );
    },
  );

  /// The widest width up to [room] at which the last line holds two words or
  /// more, in as many lines; null when the text needs no help, or can't have it.
  double? _width(BuildContext context, TextStyle style, double room) {
    if (!room.isFinite || text.contains('\n')) return null;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: textAlign,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    int lines(double width) => (painter..layout(maxWidth: width)).computeLineMetrics().length;
    // Whether the last line, as last laid out, is a single word.
    bool lonely() {
      final end = text.trimRight().length;
      final last = painter.getLineBoundary(TextPosition(offset: end - 1));
      return !text.substring(last.start, end).trim().contains(' ');
    }

    try {
      final count = lines(room);
      // More than a few lines is no longer a sentence or two: the room is
      // still opening, as the settings panel slides wider, and each width
      // there would cost its own search.
      if (count < 2 || count > 6 || !lonely()) return null;
      // The narrowest width that keeps that many lines evens them out.
      var low = 0.0, high = room;
      for (var i = 0; i < 10; i++) {
        final mid = (low + high) / 2;
        if (lines(mid) > count) {
          low = mid;
        } else {
          high = mid;
        }
      }
      lines(high);
      if (lonely()) return null;
      // From there out to [room], the last line only loses words.
      low = high;
      high = room;
      for (var i = 0; i < 8; i++) {
        final mid = (low + high) / 2;
        lines(mid);
        if (lonely()) {
          high = mid;
        } else {
          low = mid;
        }
      }
      return low;
    } finally {
      painter.dispose();
    }
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
    width: 42,
    height: 24,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: on ? const Color(0xE6FFFFFF) : const Color(0x40FFFFFF),
      borderRadius: BorderRadius.circular(12),
    ),
    child: AnimatedAlign(
      duration: Look.fast,
      curve: Look.ease,
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      child: SizedBox.square(
        dimension: 20,
        child: DecoratedBox(
          decoration: BoxDecoration(color: on ? const Color(0xFF1C1C1E) : Look.white, shape: BoxShape.circle),
        ),
      ),
    ),
  );
}

/// A see-through route for menus and panels: fades in, sliding from [from],
/// over the screen darkened by [barrier].
PageRouteBuilder<R> overlayRoute<R>(
  WidgetBuilder builder, {
  Offset from = Offset.zero,
  Color barrier = const Color(0x33000000),
}) => PageRouteBuilder<R>(
  opaque: false,
  barrierColor: barrier,
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
