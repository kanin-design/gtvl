import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'native.dart';
import 'services.dart';
import 'tile.dart';
import 'ui.dart';

/// One row of a [GlassMenu].
class MenuItem {
  const MenuItem(this.label, this.onPressed, {this.icon, this.destructive = false});

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  /// Red, for removing or deleting.
  final bool destructive;
}

/// A centred frosted-glass menu: a header, groups of rows split by a
/// full-width hairline (rows within a group by an inset one), and an
/// optional centred action at the bottom. Focus fills a row as in settings.
class GlassMenu extends StatefulWidget {
  const GlassMenu({super.key, required this.title, this.subtitle, this.leading, required this.groups, this.footer});

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<List<MenuItem>> groups;
  final MenuItem? footer;

  @override
  State<GlassMenu> createState() => _GlassMenuState();
}

class _GlassMenuState extends State<GlassMenu> {
  /// The row in focus, by its place among all rows. The inset lines beside
  /// it hide, so its fill meets the rows above and below in a straight edge.
  final _focused = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _focused.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    var index = 0;
    for (final group in widget.groups) {
      if (rows.isNotEmpty) rows.add(const Hairline());
      for (var i = 0; i < group.length; i++, index++) {
        final row = index;
        if (i > 0) rows.add(_Divider(_focused, below: row));
        rows.add(
          _MenuRow(
            group[i],
            autofocus: rows.isEmpty,
            onFocusChange: (focused) {
              if (focused) {
                _focused.value = row;
              } else if (_focused.value == row) {
                _focused.value = null;
              }
            },
          ),
        );
      }
    }
    return Center(
      child: SizedBox(
        width: 360,
        child: Glass(
          tint: const Color(0xA61C1C1E),
          sigma: 30,
          radius: BorderRadius.circular(22),
          rim: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Column(
                  children: [
                    if (widget.leading case final leading?) ...[leading, const SizedBox(height: 8)],
                    Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      style: Look.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                    // A sentence or two reads better from the left.
                    if (widget.subtitle case final subtitle?)
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
              Flexible(
                child: FocusTraversalGroup(
                  policy: smoothTraversal,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(mainAxisSize: MainAxisSize.min, children: rows),
                  ),
                ),
              ),
              if (widget.footer case final footer?) ...[
                const Hairline(),
                Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: _MenuRow(footer, centered: true)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The inset line between two rows of a group, hidden while either has focus.
class _Divider extends StatelessWidget {
  const _Divider(this.focused, {required this.below});

  final ValueListenable<int?> focused;

  /// The row under the line; the one above it is the row before.
  final int below;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: focused,
    builder: (context, row, line) => Opacity(opacity: row == below || row == below - 1 ? 0 : 1, child: line),
    // Level with the rows' text: their margin, padding, icon and gap.
    child: const Hairline(indent: 46),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.item, {this.autofocus = false, this.centered = false, this.onFocusChange});

  final MenuItem item;
  final bool autofocus;
  final bool centered;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: item.onPressed,
    onFocusChange: onFocusChange,
    builder: (context, focused) {
      final color = (item.destructive ? Look.danger : Look.white).withValues(alpha: focused ? 1 : 0.88);
      final text = Text(item.label, style: Look.body.copyWith(color: color));
      return AnimatedContainer(
        duration: Look.fast,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: focused ? Look.focusFill : const Color(0x00FFFFFF),
          border: Border.all(color: focused ? Look.focusEdge : const Color(0x00FFFFFF)),
          borderRadius: BorderRadius.circular(10),
        ),
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: centered ? Alignment.center : Alignment.centerLeft,
        child: centered
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.icon != null) ...[Icon(item.icon, size: 18, color: color), const SizedBox(width: 8)],
                  text,
                ],
              )
            : Row(
                children: [
                  SizedBox(width: 18, child: item.icon == null ? null : Icon(item.icon, size: 18, color: color)),
                  const SizedBox(width: 12),
                  Expanded(child: text),
                ],
              ),
      );
    },
  );
}

/// Asks the user to turn on GTVL buttons, which only Android's own settings
/// can do. TVs rarely open straight to its switch, so it says where that is.
Future<void> showButtonsPrompt(BuildContext context) {
  final navigator = Navigator.of(context);
  return navigator.push(
    overlayRoute(
      barrier: const Color(0x59000000),
      (context) => GlassMenu(
        leading: const Icon(Icons.settings_remote_outlined, size: 30, color: Look.white),
        title: 'Turn on button remapping',
        subtitle:
            'In Android settings, go to Device Preferences › Accessibility › Services › GTVL buttons, '
            'and turn it on. On Google TV, Accessibility is under System. Android will warn that GTVL could see '
            'what you type: GTVL only acts on the buttons you change, and never reads the screen.',
        groups: [
          [
            MenuItem('Open Android settings', () {
              navigator.pop();
              Native.buttonSettings();
            }, icon: Icons.open_in_new),
          ],
        ],
        footer: MenuItem('Not now', navigator.pop),
      ),
    ),
  );
}

/// The menu shown when OK is held on an app. [onMove] lets the dock enter
/// its move mode for that app.
Future<void> showAppMenu(BuildContext context, AppInfo app, {VoidCallback? onMove}) {
  final s = Services.of(context);
  final navigator = Navigator.of(context);
  void then(VoidCallback action) {
    navigator.pop();
    action();
  }

  return navigator.push(
    overlayRoute(barrier: const Color(0x59000000), (context) {
      final inDock = s.apps.inDock(app.package);
      return GlassMenu(
        leading: SizedBox(
          width: 96,
          height: 54,
          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: TileFace(app)),
        ),
        title: app.label,
        groups: [
          [
            MenuItem(
              'Open',
              () => then(() async {
                if (!await Native.launch(app.package)) s.notice.show("Couldn't open ${app.label}");
              }),
              icon: Icons.open_in_new,
            ),
            // A filled star while the app is a favourite, in the dock.
            MenuItem(
              'Favourite',
              () => then(() => s.apps.toggleDock(app.package)),
              icon: inDock ? Icons.star_rounded : Icons.star_outline_rounded,
            ),
            if (onMove != null) MenuItem('Move', () => then(onMove), icon: Icons.open_with),
            MenuItem('Hide', () => then(() => s.apps.hide(app.package)), icon: Icons.visibility_off_outlined),
          ],
          [MenuItem('App info', () => then(() => Native.appInfo(app.package)), icon: Icons.info_outline)],
        ],
        // Android won't uninstall an app built into the TV.
        footer: app.system
            ? null
            : MenuItem(
                'Uninstall',
                () => then(() => Native.uninstall(app.package)),
                icon: Icons.delete_outline_rounded,
                destructive: true,
              ),
      );
    }),
  );
}
