import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'services.dart';

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

  static const body = TextStyle(fontSize: 15, color: Color(0xF2FFFFFF), decoration: TextDecoration.none);
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
    this.autofocus = false,
  });

  final Widget Function(BuildContext context, bool focused) builder;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// Sees every key first, e.g. arrows while something is being moved.
  final KeyEventResult Function(KeyEvent event)? onKey;
  final bool autofocus;

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
    autofocus: widget.autofocus,
    onKeyEvent: _onKey,
    onFocusChange: (focused) {
      if (!focused) {
        _hold?.cancel();
        _hold = null;
      }
      setState(() => _focused = focused);
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

/// Scrolls the nearest scrollable so [context] is fully in view with a margin.
void reveal(BuildContext context, {double margin = 28}) {
  final box = context.findRenderObject();
  final position = Scrollable.maybeOf(context)?.position;
  if (box == null || position == null) return;
  final viewport = RenderAbstractViewport.of(box);
  final atStart = viewport.getOffsetToReveal(box, 0).offset - margin;
  final atEnd = viewport.getOffsetToReveal(box, 1).offset + margin;
  final target = position.pixels > atStart ? atStart : (position.pixels < atEnd ? atEnd : null);
  if (target == null) return;
  position.animateTo(
    target.clamp(position.minScrollExtent, position.maxScrollExtent),
    duration: Look.medium,
    curve: Look.ease,
  );
}

/// Frosted glass: blurs what is behind it and tints it. Plain tint when blur
/// is switched off.
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
    final blur = Services.of(context).config.blur;
    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: blur ? tint : tint.withValues(alpha: (tint.a * 2.5).clamp(0.0, 0.92)),
        borderRadius: radius,
        border: border,
      ),
      child: child,
    );
    return ClipRRect(
      borderRadius: radius,
      child: blur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: body,
            )
          : body,
    );
  }
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

/// An on/off switch, drawn small.
class Toggle extends StatelessWidget {
  const Toggle({super.key, required this.on});

  final bool on;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: Look.fast,
    width: 34,
    height: 20,
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: on ? Look.white : const Color(0x33FFFFFF),
      borderRadius: BorderRadius.circular(10),
    ),
    child: AnimatedAlign(
      duration: Look.fast,
      curve: Look.ease,
      alignment: on ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(color: on ? const Color(0xFF1C1C1E) : Look.white, shape: BoxShape.circle),
      ),
    ),
  );
}

/// A settings row: icon, label, then a value, a switch or a chevron.
class SettingRow extends StatelessWidget {
  const SettingRow(
    this.label, {
    super.key,
    this.icon,
    this.value,
    this.toggle,
    this.chevron = false,
    this.note,
    this.autofocus = false,
    this.onPressed,
    this.onKey,
  });

  final String label;
  final IconData? icon;
  final String? value;
  final bool? toggle;
  final bool chevron;
  final String? note;
  final bool autofocus;
  final VoidCallback? onPressed;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: onPressed,
    onKey: onKey,
    builder: (context, focused) => AnimatedContainer(
      duration: Look.fast,
      curve: Look.ease,
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: focused ? Look.focusFill : const Color(0x00FFFFFF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: Look.white.withValues(alpha: focused ? 1 : 0.7)),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: Look.body),
                if (note != null) Text(note!, style: Look.small),
              ],
            ),
          ),
          if (value != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(value!, style: Look.value),
            ),
          if (toggle != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Toggle(on: toggle!),
            ),
          if (chevron) const Icon(Icons.chevron_right, size: 18, color: Look.dim),
        ],
      ),
    ),
  );
}

/// Small explanatory text in a panel or menu.
class Note extends StatelessWidget {
  const Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
    child: Text(text, style: Look.small),
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
