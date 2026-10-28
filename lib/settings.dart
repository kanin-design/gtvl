import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'native.dart';
import 'services.dart';
import 'ui.dart';
import 'wallpaper.dart';

/// Opens the settings panel from the left.
Future<void> showSettings(BuildContext context) =>
    Navigator.of(context).push(overlayRoute((_) => const SettingsPanel(), from: const Offset(-0.08, 0)));

enum _Page { main, wallpaper, topBar, hidden, about }

const _titles = {
  _Page.main: 'Settings',
  _Page.wallpaper: 'Wallpaper',
  _Page.topBar: 'Top bar',
  _Page.hidden: 'Hidden apps',
  _Page.about: 'About',
};

const _wallpaperNames = {'aerials': 'Apple aerials', 'gradient': 'Gradient', 'video': 'Video', 'image': 'Picture'};
const _qualityNames = {'1080p': '1080p', '1080p_hdr': '1080p HDR', '4k': '4K', '4k_hdr': '4K HDR'};
const _iconNames = {'settings': 'Settings', 'network': 'Network', 'vpn': 'VPN'};
const _iconIcons = {'settings': Icons.settings_outlined, 'network': Icons.wifi, 'vpn': Icons.vpn_lock_outlined};

/// A full-height sheet of frosted glass on the left, with square edges.
/// Back goes up one page, then closes it.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final Services s = Services.of(context);
  final _pages = [_Page.main];

  /// The top-bar icon being moved, if any.
  String? _moving;

  void _open(_Page page) => setState(() => _pages.add(page));

  /// The value after [current] in [values], wrapping around.
  static T _cycle<T>(List<T> values, T current) => values[(values.indexOf(current) + 1) % values.length];

  @override
  Widget build(BuildContext context) {
    final page = _pages.last;
    return PopScope(
      canPop: _pages.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _pages.removeLast();
          _moving = null;
        });
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width * 0.34,
          height: double.infinity,
          child: Glass(
            tint: const Color(0x99141416),
            sigma: 30,
            border: const Border(right: BorderSide(color: Look.hairline)),
            child: ListenableBuilder(
              listenable: Listenable.merge([s.config, s.apps, s.status]),
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 12),
                    child: Text(_titles[page]!, style: Look.title),
                  ),
                  const Hairline(),
                  Expanded(
                    child: FocusTraversalGroup(
                      policy: smoothTraversal,
                      // A new list per page, so its first row takes focus.
                      child: ListView(key: ValueKey(page), padding: const EdgeInsets.all(10), children: _rows(page)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _rows(_Page page) {
    final c = s.config;
    switch (page) {
      case _Page.main:
        return [
          SettingRow(
            'Wallpaper',
            icon: Icons.wallpaper_outlined,
            value: _wallpaperNames[c.wallpaper],
            chevron: true,
            autofocus: true,
            onPressed: () => _open(_Page.wallpaper),
          ),
          SettingRow(
            'Top bar',
            icon: Icons.space_dashboard_outlined,
            chevron: true,
            onPressed: () => _open(_Page.topBar),
          ),
          SettingRow(
            'Hidden apps',
            icon: Icons.visibility_off_outlined,
            value: '${s.apps.hidden.length}',
            chevron: true,
            onPressed: () => _open(_Page.hidden),
          ),
          SettingRow(
            'Glass blur',
            icon: Icons.blur_on,
            toggle: c.blur,
            onPressed: () {
              c.blur = !c.blur;
              c.changed();
            },
          ),
          SettingRow('Android settings', icon: Icons.tune, onPressed: Native.openSettings),
          SettingRow('About', icon: Icons.info_outline, chevron: true, onPressed: () => _open(_Page.about)),
        ];
      case _Page.wallpaper:
        final kinds = ['aerials', 'gradient', if (c.videoPath != null) 'video', if (c.imagePath != null) 'image'];
        return [
          SettingRow(
            'Background',
            icon: Icons.wallpaper_outlined,
            value: _wallpaperNames[c.wallpaper],
            autofocus: true,
            onPressed: () {
              c.wallpaper = _cycle(kinds, c.wallpaper);
              s.caption.value = null;
              c.changed();
            },
          ),
          if (c.wallpaper == 'aerials')
            SettingRow(
              'Quality',
              icon: Icons.high_quality_outlined,
              value: _qualityNames[c.aerialQuality],
              onPressed: () {
                c.aerialQuality = _cycle(Aerials.qualities, c.aerialQuality);
                c.changed();
              },
            ),
          if (c.wallpaper == 'gradient')
            SettingRow(
              'Colours',
              icon: Icons.gradient,
              value: gradients[c.gradient.clamp(0, gradients.length - 1)].$1,
              onPressed: () {
                c.gradient = (c.gradient + 1) % gradients.length;
                c.changed();
              },
            ),
          const Note(
            'Aerials stream Apple TV films; 4K and HDR need a fast connection and a TV that shows them. '
            'To use your own video or picture, set "videoPath" or "imagePath" in config.json.',
          ),
        ];
      case _Page.topBar:
        final vpnApps = s.status.vpnApps;
        return [
          for (var i = 0; i < c.topIcons.length; i++) _iconRow(c.topIcons[i], autofocus: i == 0),
          const Note('OK shows or hides an icon. Left or Right picks it up, Up and Down move it, OK puts it down.'),
          if (vpnApps.isNotEmpty)
            SettingRow(
              'VPN app',
              icon: Icons.vpn_lock_outlined,
              value: s.status.vpnApp?.name,
              onPressed: () {
                final next = _cycle(vpnApps, s.status.vpnApp!);
                c.vpnApp = next.package;
                c.changed();
              },
            ),
          SettingRow(
            '24-hour clock',
            icon: Icons.schedule,
            toggle: c.clock24,
            onPressed: () {
              c.clock24 = !c.clock24;
              c.changed();
            },
          ),
        ];
      case _Page.hidden:
        final hidden = s.apps.hidden;
        if (hidden.isEmpty) return const [Note('No hidden apps. Hold OK on an app and choose Hide.')];
        return [
          for (var i = 0; i < hidden.length; i++)
            SettingRow(
              hidden[i].label,
              key: ValueKey(hidden[i].package),
              icon: Icons.visibility_outlined,
              value: 'Show',
              autofocus: i == 0,
              onPressed: () => s.apps.unhide(hidden[i].package),
            ),
        ];
      case _Page.about:
        return const [
          Note('GTVL 0.1: a clean, light home screen for Android TV.'),
          Note('Aerial films by Apple. The list of films comes from the Overflight project (Apache-2.0).'),
        ];
    }
  }

  Widget _iconRow(String id, {required bool autofocus}) {
    final c = s.config;
    final shown = !c.topHidden.contains(id);
    final moving = _moving == id;
    return SettingRow(
      _iconNames[id]!,
      key: ValueKey(id),
      icon: moving ? Icons.swap_vert : _iconIcons[id],
      toggle: shown,
      autofocus: autofocus,
      note: moving
          ? 'Up or Down, then OK'
          : (id == 'settings' && !shown ? 'Still appears when you move into the top bar' : null),
      onPressed: () {
        if (shown) {
          c.topHidden.add(id);
        } else {
          c.topHidden.remove(id);
        }
        c.changed();
      },
      onKey: (event) => _onIconKey(id, event),
    );
  }

  /// Left or Right picks an icon up; Up and Down move it; anything else puts it down.
  KeyEventResult _onIconKey(String id, KeyEvent event) {
    if (event is! KeyDownEvent) return _moving == id ? KeyEventResult.handled : KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_moving != id) {
      if (key != LogicalKeyboardKey.arrowLeft && key != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
      setState(() => _moving = id);
      return KeyEventResult.handled;
    }
    final order = s.config.topIcons;
    final i = order.indexOf(id);
    final to = key == LogicalKeyboardKey.arrowUp ? i - 1 : (key == LogicalKeyboardKey.arrowDown ? i + 1 : null);
    if (to == null) {
      setState(() => _moving = null);
    } else if (to >= 0 && to < order.length) {
      order
        ..removeAt(i)
        ..insert(to, id);
      s.config.changed();
    }
    return KeyEventResult.handled;
  }
}
