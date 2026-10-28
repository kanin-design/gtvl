import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'native.dart';
import 'pictures.dart';
import 'services.dart';
import 'ui.dart';
import 'wallpaper.dart';

/// Opens the settings panel from the left.
Future<void> showSettings(BuildContext context) =>
    Navigator.of(context).push(overlayRoute((_) => const SettingsPanel(), from: const Offset(-0.06, 0)));

/// The top level of settings: each opens a page beside it, except Android
/// settings, which opens the system's own.
enum _Section {
  wallpaper('Wallpaper', Icons.wallpaper_outlined),
  dock('Dock', Icons.view_day_outlined),
  topBar('Top bar', Icons.space_dashboard_outlined),
  apps('Apps', Icons.apps),
  android('Android settings', Icons.settings_outlined),
  about('About', Icons.info_outline);

  const _Section(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get hasPage => this != android;
}

// Choices, as (value, label). Values match the defaults in Config.
const _qualities = [('1080p', '1080p'), ('1080p_hdr', '1080p HDR'), ('4k', '4K'), ('4k_hdr', '4K HDR')];
const _speeds = [(0.5, 'Slow'), (0.75, 'Relaxed'), (1.0, 'Normal')];
const _nextFilm = [(0, 'When it ends'), (2, 'Every 2 minutes'), (5, 'Every 5 minutes'), (10, 'Every 10 minutes')];
const _dimming = [(0.0, 'None'), (0.1, 'Light'), (0.2, 'Medium'), (0.35, 'Strong')];
const _sizes = [('small', 'Small'), ('medium', 'Medium'), ('large', 'Large')];
const _shapes = [('wide', 'Wide banners'), ('square', 'Rounded squares')];
const _arrangements = [
  ('start', 'Left'),
  ('center', 'Centre'),
  ('evenly', 'Spread evenly'),
  ('between', 'Edge to edge'),
];
const _pictureEvery = [(1, 'Every minute'), (5, 'Every 5 minutes'), (15, 'Every 15 minutes'), (60, 'Every hour')];
const _blurs = [(0.0, 'Off'), (8.0, 'Subtle'), (16.0, 'Medium'), (24.0, 'Strong'), (40.0, 'Heavy')];
const _tints = [
  (0xFFFFFFFF, 'Frost'),
  (0xFF000000, 'Smoke'),
  (0xFF1C2A4A, 'Midnight'),
  (0xFF2E4A3A, 'Sage'),
  (0xFF4A2E3A, 'Rose'),
  (0xFF5A4A2E, 'Amber'),
];
const _tintStrengths = [(0.0, 'Clear'), (0.05, 'Light'), (0.08, 'Medium'), (0.16, 'Strong'), (0.32, 'Dense')];
const _lineWidths = [(0.0, 'None'), (1.0, 'Hairline'), (1.5, 'Thin'), (2.5, 'Bold')];
const _lineBrightness = [(0.06, 'Faint'), (0.12, 'Soft'), (0.24, 'Bright'), (0.45, 'White')];
const _sceneNames = {'space': 'Space', 'underwater': 'Underwater', 'cities': 'Cities', 'landscapes': 'Landscapes'};
const _iconNames = {'settings': 'Settings', 'network': 'Network', 'vpn': 'VPN'};

/// [text], cut to fit beside a row's label.
String _short(String text) => text.length <= 16 ? text : '${text.substring(0, 15)}…';

/// The label of [value] among [options].
String _label<T>(List<(T, String)> options, T value) =>
    options.firstWhere((option) => option.$1 == value, orElse: () => options.first).$2;

const _focusFill = Color(0x2EFFFFFF);
const _openFill = Color(0x17FFFFFF);
const _soft = Color(0xA6FFFFFF);
const _quiet = Color(0x73FFFFFF);

/// One level of settings: its title and rows. Rows are built afresh each
/// time, so they always show current values.
class _Page {
  _Page(this.title, this.rows);

  final String title;
  final List<Widget> Function() rows;

  /// The row that opened the next level, highlighted while that level is open.
  String? opened;
}

/// Tells rows whether they sit in a folded column, and which row there
/// opened the level beside it.
class _Column extends InheritedWidget {
  const _Column({required this.folded, this.opened, required super.child});

  final bool folded;
  final String? opened;

  static _Column? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Column>();

  @override
  bool updateShouldNotify(_Column old) => folded != old.folded || opened != old.opened;
}

/// Settings as a hierarchy of columns: the sections fold into a rail of
/// icons, and every level folds into a narrow column behind a divider when a
/// deeper one opens beside it. A breadcrumb on top shows where you are.
///
/// Right or OK goes a level deeper, Left or Back a level up; Right on the
/// top level closes settings.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final Services s = Services.of(context);
  final _sectionNodes = {for (final section in _Section.values) section: FocusNode(debugLabel: section.name)};
  final _rail = FocusScopeNode(debugLabel: 'settings rail');
  final _active = FocusScopeNode(debugLabel: 'settings page');

  /// The open section; null while the full list shows.
  _Section? _section;

  /// Its levels, the deepest last.
  final _pages = <_Page>[];

  /// The top-bar icon being moved, if any.
  String? _moving;

  /// Wallpapers to download, once found.
  List<({String name, String url})>? _online;
  Future<void>? _finding;

  /// The wallpaper downloading now, and the last one that failed.
  String? _downloading, _failed;

  /// The user did not allow reading pictures.
  bool _storageDenied = false;

  @override
  void dispose() {
    for (final node in _sectionNodes.values) {
      node.dispose();
    }
    _rail.dispose();
    _active.dispose();
    super.dispose();
  }

  void _openSection(_Section section, {bool focus = true}) {
    if (!section.hasPage) {
      Native.openSettings();
      return;
    }
    setState(() {
      _section = section;
      _pages
        ..clear()
        ..add(_Page(section.label, () => _rowsFor(section)));
      _moving = null;
    });
    if (focus) _focusRow();
  }

  /// Opens [page] beside the current level, which folds.
  void _push(_Page page) {
    final opener = _labelOf(FocusManager.instance.primaryFocus);
    setState(() {
      _pages.last.opened = opener;
      _pages.add(page);
    });
    _focusRow();
  }

  void _back() {
    if (_moving != null) {
      setState(() => _moving = null);
    } else if (_pages.length > 1) {
      setState(_pages.removeLast);
      // Back on the row that opened the level just closed.
      _focusRow(_pages.last.opened);
    } else if (_section != null) {
      final section = _section!;
      setState(() {
        _section = null;
        _pages.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _sectionNodes[section]!.requestFocus());
    }
  }

  /// Once the deepest level is built, focuses its row labelled [label], or
  /// else its first row; with no rows, the level itself, so Left still works.
  void _focusRow([String? label]) => WidgetsBinding.instance.addPostFrameCallback((_) {
    final rows = _active.traversalDescendants;
    (rows.where((node) => _labelOf(node) == label).firstOrNull ?? rows.firstOrNull ?? _active).requestFocus();
  });

  /// The label of the row [node] belongs to.
  static String? _labelOf(FocusNode? node) => node?.context?.findAncestorWidgetOfExactType<_Row>()?.label;

  /// A level of [options] with a check on the current one. Choosing applies
  /// at once and stays, so the change shows behind the panel.
  void _choose<T>(
    String title,
    List<(T, String)> options,
    T Function() current,
    void Function(T value) apply, {
    List<Color> Function(T value)? swatch,
  }) => _push(
    _Page(title, () {
      final now = current();
      return [
        for (final (value, label) in options)
          _Row(
            label,
            checked: value == now,
            swatch: swatch?.call(value),
            onPressed: () {
              apply(value);
              s.config.changed();
            },
          ),
      ];
    }),
  );

  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    if (_section == null) {
      // Right on the top level: back to the home screen.
      Navigator.of(context).pop();
    } else {
      final last = _active.focusedChild;
      if (last != null) {
        last.requestFocus();
      } else {
        _focusRow();
      }
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onPageKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowLeft || _moving != null) {
      return KeyEventResult.ignored;
    }
    if (_pages.length > 1) {
      _back();
    } else {
      _sectionNodes[_section]?.requestFocus();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final listWidth = screen * 0.25;
    const railWidth = 66.0;
    final foldedWidth = screen * 0.16;
    final pageWidth = screen * 0.3;
    // At most two folded levels show; older ones make way.
    final folded = _pages.length <= 1 ? <_Page>[] : _pages.sublist((_pages.length - 3).clamp(0, 99), _pages.length - 1);
    final open = _section != null;
    return PopScope(
      canPop: !open && _moving == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedContainer(
          duration: Look.medium,
          curve: Look.ease,
          width: open ? railWidth + folded.length * foldedWidth + pageWidth : listWidth,
          height: double.infinity,
          child: Glass(
            tint: const Color(0x8C141416),
            sigma: 40,
            border: const Border(right: BorderSide(color: Look.hairline)),
            child: ListenableBuilder(
              listenable: Listenable.merge([s.config, s.apps, s.status]),
              builder: (context, _) => Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedContainer(
                    duration: Look.medium,
                    curve: Look.ease,
                    width: open ? railWidth : listWidth,
                    child: FocusScope(node: _rail, onKeyEvent: _onRailKey, child: _sections(open, listWidth)),
                  ),
                  if (open)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Breadcrumb([for (final page in _pages) page.title]),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final page in folded) ...[
                                  const SizedBox(width: 1, child: ColoredBox(color: Look.hairline)),
                                  SizedBox(
                                    width: foldedWidth - 1,
                                    child: ExcludeFocus(child: _column(page, folded: true)),
                                  ),
                                ],
                                if (folded.isNotEmpty)
                                  const SizedBox(width: 1, child: ColoredBox(color: Look.hairline)),
                                Expanded(
                                  child: FocusScope(
                                    node: _active,
                                    onKeyEvent: _onPageKey,
                                    child: _column(_pages.last, folded: false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
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

  Widget _sections(bool collapsed, double listWidth) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 30, 8, 16),
    child: Column(
      children: [
        for (final section in _Section.values) ...[
          if (section == _Section.android) const SizedBox(height: 16),
          _SectionItem(
            section: section,
            focusNode: _sectionNodes[section]!,
            width: collapsed ? 50 : listWidth - 16,
            collapsed: collapsed,
            selected: _section == section,
            autofocus: section == _Section.wallpaper,
            onPressed: () => _openSection(section),
            // In the rail, moving between icons switches the page beside it.
            onFocused: () {
              if (_section != null && section.hasPage && section != _section) _openSection(section, focus: false);
            },
          ),
        ],
      ],
    ),
  );

  /// A level's rows in a column. Folded columns are narrow, quiet and not
  /// focusable; the deepest one slides in a little from the right.
  Widget _column(_Page page, {required bool folded}) {
    final list = FocusTraversalGroup(
      policy: smoothTraversal,
      child: ListView(padding: const EdgeInsets.fromLTRB(10, 2, 10, 28), children: page.rows()),
    );
    return _Column(
      folded: folded,
      opened: page.opened,
      child: folded
          ? list
          : TweenAnimationBuilder<double>(
              key: ObjectKey(page),
              tween: Tween(begin: 0, end: 1),
              duration: Look.medium,
              curve: Look.ease,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(16 * (1 - t), 0), child: child),
              ),
              child: list,
            ),
    );
  }

  List<Widget> _rowsFor(_Section section) => switch (section) {
    _Section.wallpaper => _wallpaperRows(),
    _Section.dock => _dockRows(),
    _Section.topBar => _topBarRows(),
    _Section.apps => _appRows(),
    _Section.about => _aboutRows(),
    _Section.android => const [],
  };

  /// Choosing a kind shows it and opens its own settings beside it.
  List<Widget> _wallpaperRows() {
    final c = s.config;
    void show(String kind, _Page page) {
      c.wallpaper = kind;
      if (kind != 'aerials') s.caption.value = null;
      c.changed();
      _push(page);
    }

    return [
      const _Header('Show'),
      _Row(
        'Apple aerials',
        checked: c.wallpaper == 'aerials',
        chevron: true,
        onPressed: () => show('aerials', _Page('Apple aerials', _aerialRows)),
      ),
      _Row(
        'Gradient',
        checked: c.wallpaper == 'gradient',
        chevron: true,
        onPressed: () => show('gradient', _Page('Gradient', _gradientRows)),
      ),
      _Row(
        'Picture',
        checked: c.wallpaper == 'image',
        chevron: true,
        onPressed: () {
          _findOnline();
          final page = _Page('Picture', _pictureRows);
          // Without a picture yet, one is chosen first.
          c.imagePath == null ? _push(page) : show('image', page);
        },
      ),
      if (c.videoPath != null)
        _Row(
          'Video',
          checked: c.wallpaper == 'video',
          chevron: true,
          onPressed: () => show('video', _Page('Video', () => [_Note(c.videoPath!)])),
        ),
      const _Header('Look'),
      _Row(
        'Dimming',
        value: _label(_dimming, c.dimming),
        chevron: true,
        onPressed: () => _choose('Dimming', _dimming, () => c.dimming, (v) => c.dimming = v),
      ),
      if (c.videoPath == null) const _Note('For a video, set "videoPath" in config.json.'),
    ];
  }

  /// Looks for the wallpapers to download, once per visit to settings.
  void _findOnline() => _finding ??= Pictures.online().then((found) {
    if (mounted) setState(() => _online = found);
  });

  /// A picture or folder from storage, or a wallpaper from GTVL's collection,
  /// downloaded when chosen.
  List<Widget> _pictureRows() {
    final c = s.config;
    final path = c.wallpaper == 'image' ? c.imagePath : null;
    final fromStorage = path != null && !path.startsWith(s.files);
    return [
      _Row(
        'From storage',
        value: fromStorage ? _short(Pictures.name(path)) : null,
        chevron: true,
        onPressed: _openStorage,
      ),
      if (_storageDenied)
        const _Note('GTVL may not read your pictures. Allow it in Android settings, under Apps › GTVL › Permissions.'),
      if (fromStorage && !Pictures.isPicture(path))
        _Row(
          'Change every',
          value: _label(_pictureEvery, c.pictureMinutes),
          chevron: true,
          onPressed: () => _choose('Change every', _pictureEvery, () => c.pictureMinutes, (v) => c.pictureMinutes = v),
        ),
      const _Header('Download'),
      if (_online == null)
        const _Note('Looking for wallpapers…')
      else if (_online!.isEmpty)
        const _Note('The wallpaper collection could not be reached.')
      else
        for (final wallpaper in _online!)
          _Row(
            wallpaper.name,
            key: ValueKey(wallpaper.url),
            value: wallpaper.url == _downloading
                ? 'Downloading…'
                : (wallpaper.url == _failed ? 'Could not download' : null),
            checked: path == Pictures.saved(wallpaper.url, s.files),
            onPressed: () => _download(wallpaper.url),
          ),
    ];
  }

  /// The TV's storage and any USB drives, once the user allows reading
  /// pictures. With only one, its folders open at once.
  Future<void> _openStorage() async {
    final volumes = await Native.storage();
    if (!mounted) return;
    setState(() => _storageDenied = volumes == null);
    if (volumes == null || volumes.isEmpty) return;
    if (volumes.length == 1) return _openFolder(volumes.single.path, volumes.single.name);
    _push(
      _Page(
        'Storage',
        () => [
          for (final volume in volumes)
            _Row(
              volume.name,
              key: ValueKey(volume.path),
              chevron: true,
              onPressed: () => _openFolder(volume.path, volume.name),
            ),
        ],
      ),
    );
  }

  /// A folder's subfolders and pictures. A picture, or the whole folder shown
  /// a picture at a time, can be the wallpaper.
  Future<void> _openFolder(String path, String title) async {
    final found = await Pictures.list(path);
    if (!mounted) return;
    _push(
      _Page(title, () {
        final shown = s.config.wallpaper == 'image' ? s.config.imagePath : null;
        final count = found.pictures.length;
        return [
          if (count > 0)
            _Row(
              'Use this folder',
              value: count == 1 ? '1 picture' : '$count pictures',
              checked: shown == path,
              onPressed: () => _usePicture(path),
            ),
          for (final folder in found.folders)
            _Row(
              Pictures.name(folder),
              key: ValueKey(folder),
              chevron: true,
              onPressed: () => _openFolder(folder, Pictures.name(folder)),
            ),
          for (final picture in found.pictures)
            _Row(
              Pictures.name(picture),
              key: ValueKey(picture),
              checked: shown == picture,
              onPressed: () => _usePicture(picture),
            ),
          if (found.folders.isEmpty && count == 0) const _Note('No pictures or folders here.'),
        ];
      }),
    );
  }

  /// Shows [path], a picture or a folder of them, as the wallpaper.
  void _usePicture(String path) {
    final c = s.config;
    c.imagePath = path;
    c.wallpaper = 'image';
    s.caption.value = null;
    c.changed();
  }

  /// Downloads a wallpaper from the collection, unless it is here already,
  /// and shows it.
  Future<void> _download(String url) async {
    setState(() {
      _downloading = url;
      _failed = null;
    });
    try {
      _usePicture(await Pictures.download(url, s.files));
    } on Exception {
      _failed = url;
    } finally {
      if (mounted) setState(() => _downloading = null);
    }
  }

  List<Widget> _aerialRows() {
    final c = s.config;
    final scenesOn = Aerials.kinds.where((kind) => !c.aerialsOff.contains(kind)).length;
    return [
      _Row(
        'Quality',
        value: _label(_qualities, c.aerialQuality),
        chevron: true,
        onPressed: () => _choose('Quality', _qualities, () => c.aerialQuality, (v) => c.aerialQuality = v),
      ),
      _Row(
        'Scenes',
        value: scenesOn == Aerials.kinds.length || scenesOn == 0 ? 'All' : '$scenesOn of ${Aerials.kinds.length}',
        chevron: true,
        onPressed: () => _push(_Page('Scenes', _sceneRows)),
      ),
      _Row(
        'Speed',
        value: _label(_speeds, c.aerialSpeed),
        chevron: true,
        onPressed: () => _choose('Speed', _speeds, () => c.aerialSpeed, (v) => c.aerialSpeed = v),
      ),
      _Row(
        'Next film',
        value: _label(_nextFilm, c.aerialMinutes),
        chevron: true,
        onPressed: () => _choose('Next film', _nextFilm, () => c.aerialMinutes, (v) => c.aerialMinutes = v),
      ),
      _Row(
        'Instant start',
        note: 'Keeps one film on the TV, 250 MB',
        toggle: c.aerialCache,
        onPressed: () {
          c.aerialCache = !c.aerialCache;
          if (!c.aerialCache) s.aerials.forget();
          c.changed();
        },
      ),
    ];
  }

  List<Widget> _sceneRows() {
    final off = s.config.aerialsOff;
    return [
      for (final kind in Aerials.kinds)
        _Row(
          _sceneNames[kind]!,
          value: '${s.aerials.count(kind)} films',
          toggle: !off.contains(kind),
          onPressed: () {
            if (!off.remove(kind)) off.add(kind);
            s.config.changed();
          },
        ),
      const _Note('With every scene off, all of them play.'),
    ];
  }

  List<Widget> _gradientRows() {
    final c = s.config;
    return [
      for (var i = 0; i < gradients.length; i++)
        _Row(
          gradients[i].$1,
          swatch: gradients[i].$2,
          checked: c.gradient == i,
          onPressed: () {
            c.gradient = i;
            c.changed();
          },
        ),
    ];
  }

  List<Widget> _dockRows() {
    final c = s.config;
    return [
      _Row(
        'Size',
        value: _label(_sizes, c.dockSize),
        chevron: true,
        onPressed: () => _choose('Size', _sizes, () => c.dockSize, (v) => c.dockSize = v),
      ),
      _Row(
        'Shape',
        value: _label(_shapes, c.tileShape),
        chevron: true,
        onPressed: () => _choose('Shape', _shapes, () => c.tileShape, (v) => c.tileShape = v),
      ),
      _Row(
        'Arrange',
        value: _label(_arrangements, c.dockAlign),
        chevron: true,
        onPressed: () => _choose('Arrange', _arrangements, () => c.dockAlign, (v) => c.dockAlign = v),
      ),
      _Row('Glass', chevron: true, onPressed: () => _push(_Page('Glass', _glassRows))),
      const _Note('Size and shape apply to every app, in the dock and below it.'),
    ];
  }

  List<Widget> _glassRows() {
    final c = s.config;
    return [
      _Row(
        'Blur',
        value: _label(_blurs, c.glassBlur),
        chevron: true,
        onPressed: () => _choose('Blur', _blurs, () => c.glassBlur, (v) => c.glassBlur = v),
      ),
      _Row(
        'Tint',
        value: _label(_tints, c.glassTint),
        swatch: [Color(c.glassTint)],
        chevron: true,
        onPressed: () => _choose('Tint', _tints, () => c.glassTint, (v) => c.glassTint = v, swatch: (v) => [Color(v)]),
      ),
      _Row(
        'Tint strength',
        value: _label(_tintStrengths, c.glassTintAlpha),
        chevron: true,
        onPressed: () => _choose('Tint strength', _tintStrengths, () => c.glassTintAlpha, (v) => c.glassTintAlpha = v),
      ),
      _Row(
        'Lines',
        value: _label(_lineWidths, c.lineWidth),
        chevron: true,
        onPressed: () => _choose('Lines', _lineWidths, () => c.lineWidth, (v) => c.lineWidth = v),
      ),
      if (c.lineWidth > 0)
        _Row(
          'Line brightness',
          value: _label(_lineBrightness, c.lineAlpha),
          chevron: true,
          onPressed: () => _choose('Line brightness', _lineBrightness, () => c.lineAlpha, (v) => c.lineAlpha = v),
        ),
      const _Note('Changes show on the dock at once. Less blur is lighter work for the TV.'),
    ];
  }

  List<Widget> _topBarRows() {
    final c = s.config;
    final vpnApps = s.status.vpnApps;
    return [
      const _Header('Icons'),
      for (final id in c.topIcons) _iconRow(id),
      const _Note('OK turns an icon on or off. Hold OK to move it, then Up or Down, and OK to put it down.'),
      if (vpnApps.isNotEmpty)
        _Row(
          'VPN app',
          value: s.status.vpnApp?.name,
          chevron: true,
          onPressed: () => _choose(
            'VPN app',
            [for (final app in vpnApps) (app.package, app.name)],
            () => s.status.vpnApp?.package ?? '',
            (v) => c.vpnApp = v,
          ),
        ),
      const _Header('Clock'),
      _Row(
        '24-hour clock',
        toggle: c.clock24,
        onPressed: () {
          c.clock24 = !c.clock24;
          c.changed();
        },
      ),
      _Row(
        'Wallpaper location',
        note: 'Under the clock',
        toggle: c.showCaption,
        onPressed: () {
          c.showCaption = !c.showCaption;
          c.changed();
        },
      ),
    ];
  }

  Widget _iconRow(String id) {
    final c = s.config;
    final shown = !c.topHidden.contains(id);
    final moving = _moving == id;
    return _Row(
      _iconNames[id]!,
      key: ValueKey(id),
      value: moving ? 'Moving' : null,
      toggle: moving ? null : shown,
      active: moving,
      note: id == 'settings' && !shown ? 'Still appears when you move into the top bar' : null,
      onPressed: () {
        if (!c.topHidden.remove(id)) c.topHidden.add(id);
        c.changed();
      },
      onLongPress: () => setState(() => _moving = id),
      onKey: moving ? (event) => _onMoveKey(id, event) : null,
    );
  }

  /// Up and Down move the icon; OK or Back puts it down.
  KeyEventResult _onMoveKey(String id, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.handled;
    final order = s.config.topIcons;
    final i = order.indexOf(id);
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp when i > 0:
        order
          ..removeAt(i)
          ..insert(i - 1, id);
        s.config.changed();
      case LogicalKeyboardKey.arrowDown when i < order.length - 1:
        order
          ..removeAt(i)
          ..insert(i + 1, id);
        s.config.changed();
      case LogicalKeyboardKey.arrowUp ||
          LogicalKeyboardKey.arrowDown ||
          LogicalKeyboardKey.arrowLeft ||
          LogicalKeyboardKey.arrowRight:
        break;
      default:
        if (event is KeyDownEvent) setState(() => _moving = null);
    }
    return KeyEventResult.handled;
  }

  List<Widget> _appRows() {
    final hidden = s.apps.hidden;
    return [
      const _Header('Hidden apps'),
      if (hidden.isEmpty) const _Note('None. Hold OK on an app and choose Hide.'),
      for (final app in hidden)
        _Row(
          app.label,
          key: ValueKey(app.package),
          value: 'Show',
          onPressed: () {
            s.apps.unhide(app.package);
            _focusRow();
          },
        ),
    ];
  }

  List<Widget> _aboutRows() => const [
    _Row('Version', value: '0.2.0'),
    _Note('GTVL: a clean, light home screen for Android TV.'),
    _Note('Aerial films by Apple. The list of films comes from the Overflight project (Apache-2.0).'),
    _Note('Text set in Inter, under the SIL Open Font License.'),
  ];
}

/// Where you are: each level's title, joined by ».
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb(this.titles);

  final List<String> titles;

  @override
  Widget build(BuildContext context) {
    // Deep in folders, the first levels make way for the last ones.
    final shown = titles.length > 4 ? ['…', ...titles.sublist(titles.length - 3)] : titles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 10),
      child: Text.rich(
        TextSpan(
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0)
                const WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.chevron_right_rounded, size: 18, color: _quiet),
                  ),
                ),
              TextSpan(
                text: shown[i],
                style: TextStyle(
                  color: i == shown.length - 1 ? Look.white : _soft,
                  fontWeight: i == shown.length - 1 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Look.body,
      ),
    );
  }
}

/// A top-level entry: an icon and its name. Folded into the rail, only the
/// icon shows. Focus gives a soft fill; the open section a fainter one.
class _SectionItem extends StatelessWidget {
  const _SectionItem({
    required this.section,
    required this.focusNode,
    required this.width,
    required this.collapsed,
    required this.selected,
    required this.autofocus,
    required this.onPressed,
    required this.onFocused,
  });

  final _Section section;
  final FocusNode focusNode;
  final double width;
  final bool collapsed;
  final bool selected;
  final bool autofocus;
  final VoidCallback onPressed;
  final VoidCallback onFocused;

  @override
  Widget build(BuildContext context) => Pressable(
    focusNode: focusNode,
    autofocus: autofocus,
    onPressed: onPressed,
    onFocusChange: (focused) {
      if (focused) onFocused();
    },
    builder: (context, focused) => Align(
      alignment: Alignment.centerLeft,
      child: AnimatedScale(
        scale: focused ? 1.02 : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.medium,
          curve: Look.ease,
          width: width,
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 1),
          clipBehavior: Clip.hardEdge,
          decoration: BoxDecoration(
            color: focused ? _focusFill : (selected ? _openFill : const Color(0x00FFFFFF)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 11),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(8)),
                  child: Icon(section.icon, size: 17, color: focused || selected ? Look.white : _soft),
                ),
                const SizedBox(width: 14),
                AnimatedOpacity(
                  opacity: collapsed ? 0 : 1,
                  duration: Look.fast,
                  child: Text(section.label, style: Look.body.copyWith(color: focused ? Look.white : _soft)),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// A settings row: plain until focused, then a soft fill. In a folded column
/// it shrinks to its label, and the row that opened the next level keeps a
/// faint fill.
class _Row extends StatelessWidget {
  const _Row(
    this.label, {
    super.key,
    this.value,
    this.note,
    this.swatch,
    this.toggle,
    this.checked = false,
    this.chevron = false,
    this.active = false,
    this.onPressed,
    this.onLongPress,
    this.onKey,
  });

  final String label;
  final String? value;
  final String? note;
  final List<Color>? swatch;
  final bool? toggle;
  final bool checked;

  /// Opens a deeper level; Right does too.
  final bool chevron;
  final bool active;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) {
    final column = _Column.of(context);
    if (column?.folded ?? false) return _folded(column!.opened == label);
    return Pressable(
      onPressed: onPressed,
      onLongPress: onLongPress,
      onKey: (event) {
        final custom = onKey?.call(event) ?? KeyEventResult.ignored;
        if (custom != KeyEventResult.ignored) return custom;
        if (chevron && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          onPressed?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) => AnimatedScale(
        scale: focused ? 1.02 : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.fast,
          curve: Look.ease,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: focused ? _focusFill : (active ? _openFill : const Color(0x00FFFFFF)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              if (swatch != null) ...[_Swatch(swatch!), const SizedBox(width: 12)],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: Look.body.copyWith(color: focused ? Look.white : const Color(0xE6FFFFFF))),
                    if (note != null) Text(note!, style: Look.small.copyWith(color: _quiet)),
                  ],
                ),
              ),
              if (value != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(value!, style: Look.value.copyWith(color: _soft)),
                ),
              if (toggle != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Toggle(on: toggle!),
                ),
              if (checked)
                const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Icon(Icons.check_rounded, size: 19, color: Look.white),
                ),
              if (chevron) const Icon(Icons.chevron_right_rounded, size: 19, color: _quiet),
            ],
          ),
        ),
      ),
    );
  }

  Widget _folded(bool opened) => Container(
    margin: const EdgeInsets.symmetric(vertical: 1),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: opened ? _openFill : const Color(0x00FFFFFF),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Look.body.copyWith(fontSize: 14, color: opened ? Look.white : _quiet),
    ),
  );
}

/// A small round sample of a colour or gradient.
class _Swatch extends StatelessWidget {
  const _Swatch(this.colors);

  final List<Color> colors;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: colors.length == 1 ? colors.first : null,
      gradient: colors.length > 1
          ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors)
          : null,
      border: Border.all(color: const Color(0x4DFFFFFF)),
    ),
  );
}

/// A quiet heading above a group of rows. Hidden in folded columns.
class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => (_Column.of(context)?.folded ?? false)
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
          child: Text(
            text,
            style: Look.small.copyWith(color: _quiet, fontWeight: FontWeight.w500),
          ),
        );
}

/// Small explanatory text under a group. Hidden in folded columns.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => (_Column.of(context)?.folded ?? false)
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(text, style: Look.small.copyWith(color: _quiet)),
        );
}
