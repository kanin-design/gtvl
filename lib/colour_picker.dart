import 'package:flutter/widgets.dart';

import 'glow.dart';
import 'panel.dart';
import 'ui.dart';

/// Opens the glow's colour picker over the screen: [GlowColour.all] in a grid
/// of four by four, [current] ringed in white, and above them an app tile lit
/// in the colour in focus, which [onFocused] hears too. OK on a colour hands
/// it to [onPicked] and closes; Back closes and keeps the colour.
Future<void> showColourPicker(
  BuildContext context, {
  required String current,
  required ValueChanged<String> onPicked,
  ValueChanged<String>? onFocused,
}) => showPanel(context, (context) => _ColourPicker(current: current, onPicked: onPicked, onFocused: onFocused));

class _ColourPicker extends StatefulWidget {
  const _ColourPicker({required this.current, required this.onPicked, this.onFocused});

  final String current;
  final ValueChanged<String> onPicked;
  final ValueChanged<String>? onFocused;

  @override
  State<_ColourPicker> createState() => _ColourPickerState();
}

class _ColourPickerState extends State<_ColourPicker> {
  /// The colour in focus, which the tile above the grid shows.
  late GlowColour _shown = GlowColour.of(widget.current);

  static const _columns = 4, _size = 58.0, _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final colours = GlowColour.all;
    return Panel(
      width: _columns * _size + (_columns - 1) * _gap + 2 * 30,
      leading: _Lit(_shown),
      title: _shown.name,
      child: FocusTraversalGroup(
        policy: smoothTraversal,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30, 22, 30, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < colours.length; i += _columns) ...[
                if (i > 0) const SizedBox(height: _gap),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final colour in colours.skip(i).take(_columns))
                      _Swatch(
                        colour,
                        size: _size,
                        chosen: colour.id == widget.current,
                        onFocused: () {
                          setState(() => _shown = colour);
                          widget.onFocused?.call(colour.id);
                        },
                        onPressed: () {
                          widget.onPicked(colour.id);
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An app's tile in front of the glow, lit in [colour]: what the dock will show.
class _Lit extends StatelessWidget {
  const _Lit(this.colour);

  final GlowColour colour;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(14),
    child: AnimatedContainer(
      duration: Look.medium,
      curve: Look.ease,
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: const Color(0xFF26282D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Color.lerp(colour.swatch, Look.white, 0.25)!.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(color: colour.swatch.withValues(alpha: 0.75), blurRadius: 22, spreadRadius: 2),
          BoxShadow(color: colour.swatch.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 6),
        ],
      ),
    ),
  );
}

/// One colour of the grid: a rounded square of it, ringed in white while it
/// is the glow's; in focus it lifts and glows a little in its own colour.
class _Swatch extends StatelessWidget {
  const _Swatch(
    this.colour, {
    required this.size,
    required this.chosen,
    required this.onFocused,
    required this.onPressed,
  });

  final GlowColour colour;
  final double size;
  final bool chosen;
  final VoidCallback onFocused, onPressed;

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: chosen,
    dip: true,
    onPressed: onPressed,
    onFocusChange: (focused) {
      if (focused) onFocused();
    },
    builder: (context, focused) => AnimatedScale(
      scale: focused ? 1.14 : 1,
      duration: Look.fast,
      curve: Look.ease,
      child: AnimatedContainer(
        duration: Look.fast,
        curve: Look.ease,
        width: size,
        height: size,
        padding: const EdgeInsets.all(3.5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: chosen ? Look.white : const Color(0x00FFFFFF), width: 2.5),
          boxShadow: focused
              ? [BoxShadow(color: colour.swatch.withValues(alpha: 0.55), blurRadius: 16, spreadRadius: 1)]
              : const [],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(colour.swatch, Look.white, 0.18)!, colour.swatch],
            ),
          ),
        ),
      ),
    ),
  );
}
