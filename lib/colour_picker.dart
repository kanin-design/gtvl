import 'package:flutter/widgets.dart';

import 'panel.dart';
import 'ui.dart';

/// A colour a picker offers: its id as config.json keeps it, its name, and the colour.
typedef PickedColour = ({String id, String name, Color colour});

/// Opens a colour picker over the screen: [colours] in a grid of four by
/// four, [current] ringed in white, and above them [preview] of the colour
/// in focus, which [onFocused] hears too. OK on a colour hands it to
/// [onPicked] and closes; Back closes and keeps the colour. The glow's
/// colour and the glass's tint are picked here, each from its own colours.
Future<void> showColourPicker(
  BuildContext context, {
  required List<PickedColour> colours,
  required String current,
  required ValueChanged<String> onPicked,
  required Widget Function(Color colour) preview,
  ValueChanged<String>? onFocused,
}) => showPanel(
  context,
  (context) =>
      _ColourPicker(colours: colours, current: current, onPicked: onPicked, preview: preview, onFocused: onFocused),
);

class _ColourPicker extends StatefulWidget {
  const _ColourPicker({
    required this.colours,
    required this.current,
    required this.onPicked,
    required this.preview,
    this.onFocused,
  });

  final List<PickedColour> colours;
  final String current;
  final ValueChanged<String> onPicked;
  final Widget Function(Color colour) preview;
  final ValueChanged<String>? onFocused;

  @override
  State<_ColourPicker> createState() => _ColourPickerState();
}

class _ColourPickerState extends State<_ColourPicker> {
  /// The colour in focus, which the preview above the grid shows.
  late PickedColour _shown = widget.colours.firstWhere(
    (colour) => colour.id == widget.current,
    orElse: () => widget.colours.first,
  );

  static const _columns = 4, _size = 58.0, _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final colours = widget.colours;
    return Panel(
      width: _columns * _size + (_columns - 1) * _gap + 2 * 30,
      leading: widget.preview(_shown.colour),
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
                        colour.colour,
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

/// An app's tile in front of the dock's glow, lit in [colour]: the glow
/// picker's preview.
class LitTile extends StatelessWidget {
  const LitTile(this.colour, {super.key});

  final Color colour;

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
        border: Border.all(color: Color.lerp(colour, Look.white, 0.25)!.withValues(alpha: 0.7)),
        boxShadow: [
          BoxShadow(color: colour.withValues(alpha: 0.75), blurRadius: 22, spreadRadius: 2),
          BoxShadow(color: colour.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 6),
        ],
      ),
    ),
  );
}

/// A piece of glass tinted [colour] at [level] of 10, over a sample of
/// wallpaper colours: the tint picker's preview.
class TintedGlass extends StatelessWidget {
  const TintedGlass(this.colour, {super.key, required this.level});

  final Color colour;
  final int level;

  /// What shows through: the Dusk gradient's colours, warm to cool.
  static const _sample = [Color(0xFF5B2A5C), Color(0xFFB0544B), Color(0xFF324A5F)];

  @override
  Widget build(BuildContext context) {
    final glass = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: _sample),
        ),
        child: AnimatedContainer(
          duration: Look.fast,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: level.clamp(1, 10) / 10),
            border: Border(top: BorderSide(color: Look.white.withValues(alpha: 0.25))),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(width: 132, height: 46, child: glass),
    );
  }
}

/// One colour of the grid, ringed in white while it is the one chosen; in
/// focus it lifts and glows a little in its own colour.
class _Swatch extends StatelessWidget {
  const _Swatch(
    this.colour, {
    required this.size,
    required this.chosen,
    required this.onFocused,
    required this.onPressed,
  });

  final Color colour;
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
              ? [
                  BoxShadow(
                    color: Color.lerp(colour, Look.white, 0.2)!.withValues(alpha: 0.55),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(colour, Look.white, 0.18)!, colour],
            ),
          ),
        ),
      ),
    ),
  );
}
