import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'sounds.dart';

/// The few values the whole UI shares.
abstract final class Look {
  static const fast = Duration(milliseconds: 160);
  static const medium = Duration(milliseconds: 280);
  static const ease = Curves.easeOutCubic;

  static const white = Color(0xFFFFFFFF);
  static const dim = Color(0xB3FFFFFF);
  static const hairline = Color(0x1FFFFFFF);

  /// The faint band across a menu behind the row in focus (FocusBand).
  static const focusFill = Color(0x13FFFFFF);
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

  static const caption = TextStyle(fontSize: 13, color: Color(0xCCFFFFFF), shadows: shadow);
}

/// A face the clock can wear. Each is sized so its digits stand the same
/// height, whatever its own proportions: [time] and [date] are font sizes,
/// [timeTop] and [dateTop] how far below the top of their line the digits start.
class ClockFace {
  const ClockFace(
    this.id,
    this.label,
    this.family, {
    required this.time,
    required this.timeTop,
    required this.date,
    required this.dateTop,
    this.timeAxes = const [],
    this.dateAxes = const [],
  });

  final String id, label, family;
  final double time, timeTop, date, dateTop;
  final List<FontVariation> timeAxes, dateAxes;

  /// How tall the digits stand, in the time and the date, and the gap between.
  static const digits = 74.0, dateDigits = 17.0, gap = 11.0;

  /// Poiret One first: the default.
  static const all = [
    ClockFace('poiret', 'Poiret One', 'PoiretOne', time: 96, timeTop: 5.8, date: 22.4, dateTop: 1.4),
    ClockFace(
      'shoulders',
      'Big Shoulders Display',
      'BigShouldersDisplay',
      time: 90.9,
      timeTop: 1.4,
      date: 21.1,
      dateTop: 0.3,
      timeAxes: [FontVariation('wght', 400)],
      dateAxes: [FontVariation('wght', 400)],
    ),
    ClockFace('tulpen', 'Tulpen One', 'TulpenOne', time: 105.7, timeTop: 10.7, date: 24.6, dateTop: 2.5),
    ClockFace(
      'teko',
      'Teko Light',
      'Teko',
      time: 119,
      timeTop: 5.5,
      date: 27.2,
      dateTop: 1.2,
      timeAxes: [FontVariation('wght', 300)],
      dateAxes: [FontVariation('wght', 400)],
    ),
    ClockFace(
      'doto',
      'Doto',
      'Doto',
      time: 95.5,
      timeTop: 9.9,
      date: 24.7,
      dateTop: 2.6,
      timeAxes: [FontVariation('ROND', 100), FontVariation('wght', 700)],
      dateAxes: [FontVariation('ROND', 100), FontVariation('wght', 700)],
    ),
    ClockFace(
      'sofia',
      'Sofia Sans Extra Condensed',
      'SofiaSansExtraCondensed',
      time: 110.9,
      timeTop: 9.9,
      date: 25.7,
      dateTop: 2.3,
      timeAxes: [FontVariation('wght', 300)],
      dateAxes: [FontVariation('wght', 400)],
    ),
    ClockFace('instrument', 'Instrument Serif', 'InstrumentSerif', time: 99.3, timeTop: 2.6, date: 23.3, dateTop: 0.7),
    ClockFace(
      'jost',
      'Jost Light',
      'Jost',
      time: 102.2,
      timeTop: 3,
      date: 23.9,
      dateTop: 0.7,
      timeAxes: [FontVariation('wght', 300)],
      dateAxes: [FontVariation('wght', 400)],
    ),
  ];

  static ClockFace of(String id) => all.firstWhere((face) => face.id == id, orElse: () => all.first);
}

/// The time and, under it, the date, updated on the minute.
class Clock extends StatefulWidget {
  const Clock({super.key, required this.h24, required this.face});

  final bool h24;

  /// Its face, by its id in ClockFace.all.
  final String face;

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// Two soft shadows, so the time and date hold on bright film without a plate.
  static const _shadows = [
    Shadow(color: Color(0x73000000), blurRadius: 3, offset: Offset(0, 1)),
    Shadow(color: Color(0x59000000), blurRadius: 18),
  ];

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _timer = Timer(Duration(seconds: 60 - DateTime.now().second), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// A line of text taking up only its digits' height, from their top.
  Widget _line(InlineSpan text, {required double size, required double top, required double digits}) => Align(
    alignment: Alignment.topRight,
    widthFactor: 1,
    heightFactor: digits / size,
    child: Transform.translate(offset: Offset(0, -top), child: Text.rich(text)),
  );

  @override
  Widget build(BuildContext context) {
    final face = ClockFace.of(widget.face);
    final now = DateTime.now();
    final hour = widget.h24 ? now.hour.toString().padLeft(2, '0') : '${(now.hour + 11) % 12 + 1}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        _line(
          TextSpan(
            text: '$hour:${now.minute.toString().padLeft(2, '0')}',
            style: TextStyle(
              fontFamily: face.family,
              fontSize: face.time,
              height: 1,
              color: Look.white,
              fontVariations: face.timeAxes,
              shadows: _shadows,
            ),
            children: [
              if (!widget.h24)
                TextSpan(
                  text: now.hour < 12 ? ' am' : ' pm',
                  style: TextStyle(fontSize: face.time * 0.36, color: Look.dim),
                ),
            ],
          ),
          size: face.time,
          top: face.timeTop,
          digits: ClockFace.digits,
        ),
        const SizedBox(height: ClockFace.gap),
        _line(
          TextSpan(
            text: '${_days[now.weekday - 1]} ${now.day} ${_months[now.month - 1]}',
            style: TextStyle(
              fontFamily: face.family,
              fontSize: face.date,
              height: 1,
              color: const Color(0xEBFFFFFF),
              fontVariations: face.dateAxes,
              shadows: _shadows,
            ),
          ),
          size: face.date,
          top: face.dateTop,
          digits: ClockFace.dateDigits,
        ),
      ],
    );
  }
}

/// The top bar's icons, from Phosphor's bold set.
abstract final class Glyphs {
  static const _font = 'Phosphor';
  static const gear = IconData(0xe272, fontFamily: _font);
  static const ethernet = IconData(0xedde, fontFamily: _font);
  static const wifiNone = IconData(0xe4f0, fontFamily: _font);
  static const wifiLow = IconData(0xe4ec, fontFamily: _font);
  static const wifiMedium = IconData(0xe4ee, fontFamily: _font);
  static const wifiHigh = IconData(0xe4ea, fontFamily: _font);
  static const wifiOff = IconData(0xe4f2, fontFamily: _font);
  static const globe = IconData(0xe28e, fontFamily: _font);
  static const vpnOn = IconData(0xe40c, fontFamily: _font);
  static const vpnOff = IconData(0xe410, fontFamily: _font);
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
    this.onDown,
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

  /// OK went down (true) or came up (false) on it.
  final ValueChanged<bool>? onDown;

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
        _press();
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
        _press();
      }
    }
    return KeyEventResult.handled;
  }

  /// The press, then its sound: from the set the press may just have chosen.
  void _press() {
    final onPressed = widget.onPressed;
    if (onPressed == null) return;
    onPressed();
    Sounds.press();
  }

  void _sink(bool down) {
    if (_down == down || !mounted) return;
    widget.onDown?.call(down);
    if (widget.dip) {
      setState(() => _down = down);
    } else {
      _down = down;
    }
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
        if (_down) widget.onDown?.call(false);
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

/// GTVL's glass: a tint over what is behind it. No live blur: films play
/// on the TV's own video layer, which no TV lets an app blur, and the Shield
/// blurs nothing GTVL draws either. Over a still picture the dock lays a
/// blurred copy of it under its glass (WallpaperBlur). With [rim], light
/// catches its edge, brightest at the top left, and its tint is a touch
/// lighter at the top: a pane, not a flat plate.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.tint = const Color(0x14FFFFFF),
    this.radius = BorderRadius.zero,
    this.border,
    this.rim = false,
  });

  final Widget child;
  final Color tint;
  final BorderRadius radius;
  final BoxBorder? border;
  final bool rim;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: radius,
    child: rim
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
          ),
  );
}

/// The colours the dock's glass can be tinted, as the tint picker offers
/// them in rows of four: light to dark, then blues, greens and warm ones.
/// Smoke, the default, is the glass's dark grey as it was.
abstract final class Tints {
  static const smoke = 'smoke';

  static const all = <({String id, String name, Color colour})>[
    (id: 'frost', name: 'Frost', colour: Color(0xFFF2F4F7)),
    (id: 'mist', name: 'Mist', colour: Color(0xFFAEB4BE)),
    (id: 'graphite', name: 'Graphite', colour: Color(0xFF3A3A3C)),
    (id: smoke, name: 'Smoke', colour: Color(0xFF1C1C1E)),
    (id: 'midnight', name: 'Midnight', colour: Color(0xFF1C2A4A)),
    (id: 'navy', name: 'Navy', colour: Color(0xFF0F1E3D)),
    (id: 'ocean', name: 'Ocean', colour: Color(0xFF103A4D)),
    (id: 'teal', name: 'Teal', colour: Color(0xFF0E3B3B)),
    (id: 'forest', name: 'Forest', colour: Color(0xFF14301F)),
    (id: 'sage', name: 'Sage', colour: Color(0xFF2E4A3A)),
    (id: 'olive', name: 'Olive', colour: Color(0xFF3D3A1E)),
    (id: 'amber', name: 'Amber', colour: Color(0xFF5A4A2E)),
    (id: 'rust', name: 'Rust', colour: Color(0xFF5C2A1E)),
    (id: 'rose', name: 'Rose', colour: Color(0xFF4A2E3A)),
    (id: 'plum', name: 'Plum', colour: Color(0xFF3A1F3D)),
    (id: 'indigo', name: 'Indigo', colour: Color(0xFF2A1F4A)),
  ];

  /// The tint kept as [id]; Smoke for one unknown.
  static ({String id, String name, Color colour}) of(String id) =>
      all.firstWhere((tint) => tint.id == id, orElse: () => all[3]);

  /// The glass's tint: [id]'s colour at [level] of 10, 5 half covering what is behind it.
  static Color glass(String id, int level) => of(id).colour.withValues(alpha: level.clamp(1, 10) / 10);
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
    tint: const Color(0xC81C1C1E),
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
/// What marks the row in focus in every menu: a faint band right across
/// the menu, and a short white bar at its left end, as the settings rail
/// marks the section open beside it. [marked] shows the bar alone, for the
/// section open or the row a deeper level opened from. [overhang] is how far
/// the band reaches past the row, to the menu's edges; [barInset] how far in
/// from the band's left end the bar sits, as it does off the screen's edge.
class FocusBand extends StatelessWidget {
  const FocusBand({
    super.key,
    required this.focused,
    this.marked = false,
    this.overhang = EdgeInsets.zero,
    this.barInset = 0,
    required this.child,
  });

  final bool focused, marked;
  final EdgeInsets overhang;
  final double barInset;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    clipBehavior: Clip.none,
    children: [
      Positioned(
        left: -overhang.left,
        right: -overhang.right,
        top: 0,
        bottom: 0,
        child: AnimatedOpacity(
          opacity: focused ? 1 : 0,
          duration: Look.fast,
          child: const ColoredBox(color: Look.focusFill),
        ),
      ),
      Positioned(
        left: barInset - overhang.left,
        top: 0,
        bottom: 0,
        child: Center(
          child: AnimatedOpacity(
            opacity: focused || marked ? 1 : 0,
            duration: Look.fast,
            child: SizedBox(
              width: 3,
              height: 18,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Look.white,
                  // Square where it meets the band's end, round where it stands free.
                  borderRadius: barInset > 0
                      ? BorderRadius.circular(2)
                      : const BorderRadius.horizontal(right: Radius.circular(2)),
                ),
              ),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}

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
