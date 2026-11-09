import 'package:flutter/widgets.dart';

import 'ui.dart';

/// The frosted panel every GTVL pop-up is made on: the menu that holding OK
/// on an app opens, the glow's colour picker, the button remapper. Centred
/// over the darkened screen, [width] wide: a header of [leading], [title] and
/// [subtitle] over a hairline, then [child], which must scroll itself if it
/// can be taller than the screen. Its size follows its content smoothly, so
/// a pop-up can change what it shows in place.
///
/// What is inside is each pop-up's own; a change here changes them all.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.title, this.subtitle, this.leading, this.width = 360});

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? leading;
  final double width;

  /// The screen behind a pop-up, darkened.
  static const barrier = Color(0x59000000);

  /// The room kept round a pop-up, so a tall one never meets the screen's edge.
  static const _margin = EdgeInsets.symmetric(horizontal: 32, vertical: 28);

  @override
  Widget build(BuildContext context) => Padding(
    padding: _margin,
    child: Center(
      child: AnimatedContainer(
        duration: Look.medium,
        curve: Look.ease,
        width: width,
        child: Glass(
          // A step darker than glass that blurs: what is behind shows through as it is.
          tint: const Color(0xC81C1C1E),
          radius: BorderRadius.circular(22),
          rim: true,
          child: AnimatedSize(
            duration: Look.medium,
            curve: Look.ease,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null || leading != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Column(
                      children: [
                        if (leading case final leading?) ...[leading, const SizedBox(height: 8)],
                        if (title case final title?)
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: Look.body.copyWith(fontWeight: FontWeight.w600),
                          ),
                        // A sentence or two reads better from the left.
                        if (subtitle case final subtitle?)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Prose(
                              subtitle,
                              textAlign: subtitle.length > 80 ? TextAlign.left : TextAlign.center,
                              style: Look.small.copyWith(height: 1.4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Hairline(),
                ],
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Opens the pop-up [builder] makes over the screen, as every pop-up opens.
Future<T?> showPanel<T>(BuildContext context, WidgetBuilder builder) =>
    Navigator.of(context).push(overlayRoute<T>(builder, barrier: Panel.barrier));
