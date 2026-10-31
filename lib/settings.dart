import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'buttons.dart';
import 'media.dart';
import 'menu.dart' show showButtonsPrompt;
import 'native.dart';
import 'plex.dart';
import 'services.dart';
import 'ui.dart';
import 'updates.dart';
import 'wallpaper.dart';

/// Opens the settings panel from the left.
Future<void> showSettings(BuildContext context) =>
    Navigator.of(context).push(overlayRoute((_) => const SettingsPanel(), from: const Offset(-0.06, 0)));

/// The top level of settings: each opens a page beside it, except Android
/// settings, which opens the system's own.
enum _Section {
  wallpaper('Wallpaper', Icons.wallpaper_outlined),
  dock('Dock', Icons.view_day_outlined),
  shows('Shows', Icons.live_tv_outlined),
  topBar('Top bar', Icons.space_dashboard_outlined),
  apps('Apps', Icons.apps_outlined),
  buttons('Buttons', Icons.settings_remote_outlined),
  android('Android settings', Icons.settings_outlined),
  about('About', Icons.info_outline);

  const _Section(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get hasPage => this != android;
}

// Choices, as (value, label). Values match the defaults in Config.
const _qualities = [('1080p', '1080p'), ('1080p_hdr', '1080p HDR'), ('4k', '4K'), ('4k_hdr', '4K HDR')];
const _speeds = [(0.5, 'Half'), (0.75, 'Three quarters'), (1.0, 'Normal')];
const _nextFilm = [(0, 'When a film ends'), (2, 'Every 2 minutes'), (5, 'Every 5 minutes'), (10, 'Every 10 minutes')];
const _dimming = [(0.0, 'None'), (0.1, 'Light'), (0.2, 'Medium'), (0.35, 'Strong')];
const _sizes = [('xs', 'Extra small'), ('s', 'Small'), ('m', 'Medium'), ('l', 'Large'), ('xl', 'Extra large')];
const _shapes = [('wide', 'Wide banners'), ('square', 'Square icons')];
const _arrangements = [
  ('start', 'Left'),
  ('center', 'Centre'),
  ('evenly', 'Spread evenly'),
  ('between', 'Edge to edge'),
];
const _pictureEvery = [(1, 'Every minute'), (5, 'Every 5 minutes'), (15, 'Every 15 minutes'), (60, 'Every hour')];
const _videoLoops = [(0, 'Once'), (1, 'For 1 minute'), (5, 'For 5 minutes'), (15, 'For 15 minutes')];
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
const _glows = [(0, 'Off'), (1, '1'), (2, '2'), (3, '3')];
const _sceneNames = {'space': 'Space', 'underwater': 'Underwater', 'cities': 'Cities', 'landscapes': 'Landscapes'};
const _iconNames = {'settings': 'Settings', 'network': 'Network', 'vpn': 'VPN'};

/// Moves between rows as [smoothTraversal] does; a row near the end of its
/// level also brings the notes below it into view.
final _rowTraversal = ReadingOrderTraversalPolicy(
  requestFocusCallback: (node, {alignment, alignmentPolicy, curve, duration}) {
    node.requestFocus();
    if (node.context case final context?) reveal(context, endZone: _endZone);
  },
);

/// How close to the end of a level a row brings the rest into view: more
/// than a note or two, less than another row with its notes.
const _endZone = 120.0;

/// [text], cut to fit beside a row's label.
String _short(String text) => text.length <= 16 ? text : '${text.substring(0, 15)}…';

/// The label of [value] among [options].
String _label<T>(List<(T, String)> options, T value) =>
    options.firstWhere((option) => option.$1 == value, orElse: () => options.first).$2;

const _focusFill = Look.focusFill;
const _focusEdge = Look.focusEdge;
const _openFill = Color(0x17FFFFFF);
const _soft = Color(0xB8FFFFFF);
const _quiet = Color(0x99FFFFFF);

/// Notes under rows: quieter than labels, still easy to read.
const _noteColor = Color(0xA8FFFFFF);

/// One level of settings: its title and rows. Rows are built afresh each
/// time, so they always show current values.
class _Page {
  _Page(this.title, this.rows, {this.wide = false, this.onClose});

  final String title;
  final List<Widget> Function() rows;

  /// Holds previews, so it opens wider.
  final bool wide;

  /// Called when the level closes, however it closes.
  final VoidCallback? onClose;

  /// The row that opened the next level, highlighted while that level is
  /// open, and which of the rows of that name it was.
  String? opened;
  int openedNth = 0;
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

  /// The section opened last, where the list opens next time, until GTVL restarts.
  static _Section _last = _Section.wallpaper;

  /// Its levels, the deepest last.
  final _pages = <_Page>[];

  /// The top-bar icon being moved, if any.
  String? _moving;

  /// GTVL's collection online, by kind, once found; empty when it couldn't
  /// be reached ([_unreachable]).
  final _online = <MediaKind, List<OnlineMedia>>{};
  final _finding = <MediaKind, Future<void>>{};
  final _unreachable = <MediaKind>{};

  /// Downloads under way, as url to how much is done (0 to 1), those the
  /// user stopped, and those that failed.
  final _downloading = <String, double>{};
  final _stopping = <String>{};
  final _failed = <String>{};

  /// Videos this TV can't play, by url or path.
  final _unplayable = <String>{};

  /// Kinds the user did not allow GTVL to read from storage.
  final _denied = <MediaKind>{};

  /// What a gallery shows from storage: what was chosen when it opened, plus
  /// anything chosen since, so one dropped stays in place to pick again.
  final _fromStorage = <MediaKind, List<String>>{};

  /// Video frames and folders' first files, looked up once each.
  final _frames = <String, Future<String?>>{};
  final _firstFiles = <String, Future<String?>>{};

  /// Whether the button service is on, and the remotes connected, once asked.
  ({bool on, List<({String id, String name, List<String> keys, bool used})> remotes})? _buttons;
  StreamSubscription<Object?>? _buttonEvents;

  /// Coming back from Android settings, where the button service is turned on.
  late final _lifecycle = AppLifecycleListener(
    onResume: () {
      if (_section == _Section.buttons) _refreshButtons();
    },
  );

  @override
  void initState() {
    super.initState();
    _buttonEvents = Native.events.where((event) => event['type'] == 'buttons').listen((_) => _refreshButtons());
    _lifecycle;
  }

  @override
  void dispose() {
    _closeAll();
    _buttonEvents?.cancel();
    _lifecycle.dispose();
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
    _closeAll();
    _last = section;
    setState(() {
      _section = section;
      _pages
        ..clear()
        ..add(_Page(section.label, () => _rowsFor(section)));
      _moving = null;
    });
    if (section == _Section.buttons) _refreshButtons(prompt: focus);
    if (focus) _focusRow();
  }

  /// Lets every open level know it closes.
  void _closeAll() {
    for (final page in _pages) {
      page.onClose?.call();
    }
  }

  /// Opens [page] beside the current level, which folds, focusing its row
  /// labelled [focus], else its first; [from] is the row that opened it,
  /// when that isn't the focused one.
  void _push(_Page page, {String? from, String? focus}) {
    final focused = FocusManager.instance.primaryFocus;
    final opener = from ?? _labelOf(focused);
    // One button can be on two remotes: which of the rows so named.
    final named = [
      for (final node in _active.traversalDescendants)
        if (_labelOf(node) == opener) node,
    ];
    final nth = from == null && focused != null ? named.indexOf(focused) : -1;
    setState(() {
      _pages.last
        ..opened = opener
        ..openedNth = nth < 0 ? 0 : nth;
      _pages.add(page);
    });
    _focusRow(focus);
  }

  void _back() {
    if (_moving != null) {
      setState(() => _moving = null);
    } else if (_pages.length > 1) {
      final closing = _pages.last;
      setState(_pages.removeLast);
      closing.onClose?.call();
      // Back on the row that opened the level just closed.
      _focusRow(_pages.last.opened, _pages.last.openedNth);
    } else if (_section != null) {
      final section = _section!;
      _closeAll();
      setState(() {
        _section = null;
        _pages.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _sectionNodes[section]!.requestFocus());
    }
  }

  /// Once the deepest level is built, focuses its row labelled [label] (the
  /// [nth] of that name), or else its first row, scrolled into view; with no
  /// rows, the level itself, so Left still works. Never while a menu is open
  /// over settings.
  void _focusRow([String? label, int nth = 0]) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !(ModalRoute.isCurrentOf(context) ?? true)) return;
    final rows = _active.traversalDescendants;
    final named = label == null ? const <FocusNode>[] : rows.where((node) => _labelOf(node) == label);
    final node = named.elementAtOrNull(nth) ?? named.firstOrNull ?? rows.firstOrNull ?? _active;
    node.requestFocus();
    if (node != _active && node.context != null) reveal(node.context!, endZone: _endZone);
  });

  /// The label of the row [node] belongs to.
  static String? _labelOf(FocusNode? node) => node?.context?.findAncestorWidgetOfExactType<_Row>()?.label;

  /// A level of [options] with a check on the current one, which it opens on.
  /// Choosing applies at once and stays, so the change shows behind the panel.
  void _choose<T>(
    String title,
    List<(T, String)> options,
    T Function() current,
    void Function(T value) apply, {
    List<Color> Function(T value)? swatch,
    bool Function(T value)? enabled,
    String? note,
  }) => _push(
    _Page(title, () {
      final now = current();
      return [
        for (final (value, label) in options)
          _Row(
            label,
            checked: value == now,
            swatch: swatch?.call(value),
            enabled: enabled?.call(value) ?? true,
            onPressed: () {
              apply(value);
              s.config.changed();
            },
          ),
        if (note != null) _Note(note),
      ];
    }),
    focus: _label(options, current()),
  );

  KeyEventResult _onRailKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    if (_section == null) {
      // Right on the full list opens the section in focus, as OK does; not
      // Android settings, as Right shouldn't leave GTVL.
      final section = _Section.values.where((section) => _sectionNodes[section]!.hasPrimaryFocus).firstOrNull;
      if (section != null && section.hasPage) _openSection(section);
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
    // Among previews, Left first moves to the one beside. (A level with no
    // rows has the level itself focused, which Flutter would just focus again.)
    final focused = FocusManager.instance.primaryFocus;
    if (focused != _active && (focused?.focusInDirection(TraversalDirection.left) ?? false)) {
      return KeyEventResult.handled;
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
    final pageWidth = screen * ((_pages.lastOrNull?.wide ?? false) ? 0.42 : 0.3);
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
            tint: const Color(0xA6141416),
            sigma: 40,
            border: const Border(right: BorderSide(color: Look.hairline)),
            child: ListenableBuilder(
              listenable: Listenable.merge([s.config, s.apps, s.status, s.plex, s.appRows, s.updates]),
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
            // An update waits in About.
            badge: section == _Section.about && s.updates.waiting,
            autofocus: section == _last,
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
      policy: _rowTraversal,
      // Keyed by level, so a level shown again comes back scrolled where it was.
      child: ListView(
        key: PageStorageKey<_Page>(page),
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 28),
        children: page.rows(),
      ),
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
              child: _ScrollCue(child: list),
            ),
    );
  }

  List<Widget> _rowsFor(_Section section) => switch (section) {
    _Section.wallpaper => _wallpaperRows(),
    _Section.dock => _dockRows(),
    _Section.shows => _showRows(),
    _Section.topBar => _topBarRows(),
    _Section.apps => _appRows(),
    _Section.buttons => _buttonRows(),
    _Section.about => _aboutRows(),
    _Section.android => const [],
  };

  /// OK on a kind shows it and opens its own settings beside it; Right only
  /// opens them, to look without changing the wallpaper.
  List<Widget> _wallpaperRows() {
    final c = s.config;
    return [
      const _Header('Type'),
      _Row(
        'Apple aerials',
        checked: c.wallpaper == 'aerials',
        chevron: true,
        onPressed: () => _show('aerials', _Page('Apple aerials', _aerialRows)),
        onRight: () => _push(_Page('Apple aerials', _aerialRows)),
      ),
      _galleryRow(MediaKind.videos),
      _galleryRow(MediaKind.pictures),
      _Row(
        'Gradient',
        checked: c.wallpaper == 'gradient',
        chevron: true,
        onPressed: () => _show('gradient', _Page('Gradient', _gradientRows)),
        onRight: () => _push(_Page('Gradient', _gradientRows)),
      ),
      const _Header('Look'),
      _Row(
        'Dimming',
        value: _label(_dimming, c.dimming),
        chevron: true,
        onPressed: () => _choose('Dimming', _dimming, () => c.dimming, (v) => c.dimming = v),
      ),
    ];
  }

  /// Shows [kind] of wallpaper.
  void _use(String kind) {
    final c = s.config;
    c.wallpaper = kind;
    if (kind != 'aerials') s.caption.value = null;
    c.changed();
  }

  /// Shows [kind] of wallpaper and opens its settings beside the list.
  void _show(String kind, _Page page) {
    _use(kind);
    _push(page);
  }

  /// Atop a kind's settings, opened with Right while another kind shows: a
  /// way to show this one.
  List<Widget> _useRow(String kind) => [
    if (s.config.wallpaper != kind)
      _Row(
        'Use as wallpaper',
        note: 'Showing ${_kindNames[s.config.wallpaper] ?? 'something else'} now',
        onPressed: () {
          _use(kind);
          _focusRow();
        },
      ),
  ];

  static const _kindNames = {
    'aerials': 'Apple aerials',
    'video': 'videos',
    'image': 'pictures',
    'gradient': 'a gradient',
  };

  /// Videos or pictures: a gallery to pick from. With some picked already,
  /// OK shows them at once; Right only opens the gallery.
  Widget _galleryRow(MediaKind kind) {
    void open({required bool show}) {
      _findOnline(kind);
      _fromStorage[kind] = [
        for (final path in _chosen(kind))
          if (!_isDownload(path)) path,
      ];
      final page = _Page(kind.label, () => _galleryRows(kind), wide: true);
      if (show && _chosen(kind).isNotEmpty) {
        _show(kind.wallpaper, page);
      } else {
        _push(page);
      }
    }

    return _Row(
      kind.label,
      checked: s.config.wallpaper == kind.wallpaper,
      chevron: true,
      onPressed: () => open(show: true),
      onRight: () => open(show: false),
    );
  }

  /// What [kind] shows when it is the wallpaper.
  List<String> _chosen(MediaKind kind) => kind == MediaKind.pictures ? s.config.pictures : s.config.videos;

  /// A file downloaded from the collection, not one from storage.
  bool _isDownload(String path) => path.startsWith('${s.files}/');

  /// Looks for the collection of [kind], once per visit to settings.
  void _findOnline(MediaKind kind) => _finding[kind] ??= Media.online(kind).then((found) {
    if (!mounted) return;
    setState(() {
      _online[kind] = found ?? const [];
      if (found == null) _unreachable.add(kind);
    });
  });

  /// GTVL's collection and what was chosen from storage, as previews: OK
  /// picks one or drops it. One alone stays on (a video loops); several
  /// take turns.
  List<Widget> _galleryRows(MediaKind kind) {
    final c = s.config;
    final videos = kind == MediaKind.videos;
    final chosen = _chosen(kind);
    final online = _online[kind];
    final fromStorage = _fromStorage.putIfAbsent(kind, () => []);
    for (final path in chosen) {
      if (!_isDownload(path) && !fromStorage.contains(path)) fromStorage.add(path);
    }
    final several = chosen.length > 1 || chosen.any((path) => !kind.matches(path));
    final shuffle = videos ? c.videoShuffle : c.pictureShuffle;
    return [
      if (chosen.isNotEmpty) ..._useRow(kind.wallpaper),
      _Row('Browse storage', chevron: true, onPressed: () => _openStorage(kind)),
      if (_denied.contains(kind))
        _Note(
          "GTVL isn't allowed to see your ${kind.label.toLowerCase()}. "
          'Allow access in Android settings › Apps › GTVL › Permissions.',
        ),
      if (videos)
        _Row(
          'Play each video',
          value: _label(_videoLoops, c.videoLoopMinutes),
          note: several ? null : 'A single video loops nonstop',
          chevron: true,
          enabled: several,
          onPressed: () => _choose(
            'Play each video',
            _videoLoops,
            () => c.videoLoopMinutes,
            (v) => c.videoLoopMinutes = v,
            note: 'How long each video plays before the next one fades in. A shorter video loops until then.',
          ),
        )
      else
        _Row(
          'Next picture',
          value: _label(_pictureEvery, c.pictureMinutes),
          note: several ? null : 'Needs two or more pictures',
          chevron: true,
          enabled: several,
          onPressed: () => _choose('Next picture', _pictureEvery, () => c.pictureMinutes, (v) => c.pictureMinutes = v),
        ),
      _Row(
        'Shuffle',
        note: several ? null : 'Needs two or more ${kind.label.toLowerCase()}',
        toggle: shuffle,
        enabled: several,
        onPressed: () {
          if (videos) {
            c.videoShuffle = !shuffle;
          } else {
            c.pictureShuffle = !shuffle;
          }
          c.changed();
        },
      ),
      const _Header('GTVL collection'),
      if (online == null)
        const _Note('Looking for the collection…')
      else if (_unreachable.contains(kind))
        _Row(
          "Couldn't reach the collection",
          value: 'Try again',
          onPressed: () {
            setState(() {
              _finding.remove(kind);
              _online.remove(kind);
              _unreachable.remove(kind);
            });
            _findOnline(kind);
          },
        )
      else if (online.isEmpty)
        const _Note('Nothing in the collection yet.')
      else
        ..._grid([for (final item in online) _onlineThumb(kind, item)]),
      if (fromStorage.isNotEmpty) ...[
        const _Header('From storage'),
        ..._grid([for (final path in fromStorage) _storageThumb(kind, path)]),
      ],
      _Note(
        videos
            ? 'OK adds a video to the wallpaper, or takes it off. One video loops seamlessly; several take turns, '
                  'with a crossfade between them. A video from the collection downloads when added; OK again stops it.'
            : 'OK adds a picture to the wallpaper, or takes it off. Several take turns, with a crossfade between them. '
                  'A picture from the collection downloads when added; OK again stops it.',
      ),
    ];
  }

  /// A file in GTVL's collection, previewed from the collection itself.
  Widget _onlineThumb(MediaKind kind, OnlineMedia item) {
    final path = Media.saved(item.url, s.files, kind);
    final picked = _chosen(kind).contains(path);
    final done = _downloading[item.url];
    return _Thumb(
      item.name,
      key: ValueKey(item.url),
      picture: Image.network(
        item.preview,
        fit: BoxFit.cover,
        frameBuilder: _fadeIn,
        // A picture without a preview of its own previews itself.
        errorBuilder: (context, _, _) => kind == MediaKind.pictures
            ? Image.network(item.url, fit: BoxFit.cover, cacheWidth: 480, frameBuilder: _fadeIn, errorBuilder: _blank)
            : const SizedBox.shrink(),
      ),
      checked: picked,
      status: switch (item.url) {
        // A stop takes effect as the next piece arrives, or the wait for it runs out.
        final url when done != null => _stopping.contains(url) ? 'Stopping…' : 'Downloading',
        final url when _unplayable.contains(url) => "Can't play on this TV",
        final url when _failed.contains(url) => "Couldn't download",
        _ => null,
      },
      progress: done,
      onPressed: _unplayable.contains(item.url)
          ? null
          : done != null
          ? () => setState(() => _stopping.add(item.url))
          : () => picked ? _drop(kind, path) : _download(kind, item.url),
    );
  }

  /// A file or folder chosen from storage.
  Widget _storageThumb(MediaKind kind, String path) {
    final folder = !kind.matches(path);
    final picked = _chosen(kind).contains(path);
    return _Thumb(
      folder ? Media.name(path) : Media.stem(path),
      key: ValueKey(path),
      picture: folder ? _folderPreview(kind, path) : _preview(kind, path),
      folder: folder,
      checked: picked,
      status: _unplayable.contains(path) ? "Can't play on this TV" : null,
      onPressed: () => picked ? _drop(kind, path) : _pickPlayable(kind, path),
    );
  }

  /// Adds [path] to what [kind] shows, and shows that kind. A folder takes
  /// the place of files picked in it.
  void _pick(MediaKind kind, String path) {
    final c = s.config;
    final chosen = _chosen(kind);
    if (!kind.matches(path)) {
      chosen.removeWhere((file) => file.startsWith('$path/') && !file.substring(path.length + 1).contains('/'));
    }
    if (!chosen.contains(path)) chosen.add(path);
    c.wallpaper = kind.wallpaper;
    s.caption.value = null;
    c.changed();
  }

  /// Picks [path], unless it is a video this TV can't play.
  Future<void> _pickPlayable(MediaKind kind, String path) async {
    if (kind == MediaKind.videos && kind.matches(path) && !await Native.canPlay(path)) {
      if (mounted) setState(() => _unplayable.add(path));
      return;
    }
    _pick(kind, path);
  }

  /// Takes [path] out of what [kind] shows. A download from the collection
  /// is deleted; it comes again if picked again.
  void _drop(MediaKind kind, String path) {
    final chosen = _chosen(kind)..remove(path);
    // With nothing left of this kind the gradient shows: the list says so too.
    if (chosen.isEmpty && s.config.wallpaper == kind.wallpaper) s.config.wallpaper = 'gradient';
    s.config.changed();
    if (_isDownload(path)) Media.forget(path);
  }

  /// Drops [file] from [folder], chosen whole: its other [files] stay, picked
  /// one by one.
  void _dropFromFolder(MediaKind kind, String folder, String file, List<String> files) {
    final chosen = _chosen(kind)..remove(folder);
    chosen.addAll(files.where((other) => other != file && !chosen.contains(other)));
    s.config.changed();
  }

  /// The TV's storage and any USB drives, once the user allows reading
  /// [kind]. With only one, its folders open at once.
  Future<void> _openStorage(MediaKind kind) async {
    final volumes = await Native.storage(videos: kind == MediaKind.videos);
    if (!mounted) return;
    setState(() {
      if (volumes == null) {
        _denied.add(kind);
      } else {
        _denied.remove(kind);
      }
    });
    if (volumes == null || volumes.isEmpty) return;
    if (volumes.length == 1) return _openFolder(kind, volumes.single.path, volumes.single.name);
    _push(
      _Page(
        'Storage',
        () => [
          for (final volume in volumes)
            _Row(
              volume.name,
              key: ValueKey(volume.path),
              chevron: true,
              onPressed: () => _openFolder(kind, volume.path, volume.name),
            ),
        ],
      ),
    );
  }

  /// A folder's subfolders, and previews of its files: OK picks one or drops
  /// it, or all of them at once, which takes in files added later too.
  Future<void> _openFolder(MediaKind kind, String path, String title) async {
    final found = await Media.list(path, kind);
    if (!mounted) return;
    final files = found.files;
    _push(
      _Page(title, wide: files.isNotEmpty, () {
        final chosen = _chosen(kind);
        final whole = chosen.contains(path);
        return [
          if (files.isNotEmpty)
            _Row(
              'All in this folder',
              value: kind.count(files.length),
              toggle: whole,
              onPressed: () => whole ? _drop(kind, path) : _pick(kind, path),
            ),
          for (final folder in found.folders)
            _Row(
              Media.name(folder),
              key: ValueKey(folder),
              chevron: true,
              onPressed: () => _openFolder(kind, folder, Media.name(folder)),
            ),
          ..._grid([
            for (final file in files)
              _Thumb(
                Media.stem(file),
                key: ValueKey(file),
                picture: _preview(kind, file),
                checked: whole || chosen.contains(file),
                status: _unplayable.contains(file) ? "Can't play on this TV" : null,
                onPressed: () {
                  if (whole) {
                    _dropFromFolder(kind, path, file, files);
                  } else if (chosen.contains(file)) {
                    _drop(kind, file);
                  } else {
                    _pickPlayable(kind, file);
                  }
                },
              ),
          ]),
          if (found.folders.isEmpty && files.isEmpty) _Note('No ${kind.label.toLowerCase()} or folders here.'),
        ];
      }),
    );
  }

  /// [path] in small: the picture itself, or a frame of the video.
  Widget _preview(MediaKind kind, String path) => kind == MediaKind.pictures
      ? Image.file(File(path), fit: BoxFit.cover, cacheWidth: 480, frameBuilder: _fadeIn, errorBuilder: _blank)
      : FutureBuilder(
          future: _frames.putIfAbsent(path, () => Native.videoFrame(path)),
          builder: (context, frame) => switch (frame.data) {
            final String file => Image.file(File(file), fit: BoxFit.cover, frameBuilder: _fadeIn, errorBuilder: _blank),
            _ => const SizedBox.shrink(),
          },
        );

  /// A folder in small: its first file.
  Widget _folderPreview(MediaKind kind, String folder) => FutureBuilder(
    future: _firstFiles.putIfAbsent(
      '${kind.name} $folder',
      () => Media.list(folder, kind).then((found) => found.files.firstOrNull),
    ),
    builder: (context, first) => switch (first.data) {
      final String file => _preview(kind, file),
      _ => const SizedBox.shrink(),
    },
  );

  /// Downloads a file from the collection, unless it is here already, and
  /// picks it.
  Future<void> _download(MediaKind kind, String url) async {
    setState(() {
      _downloading[url] = 0;
      _failed.remove(url);
      // A stop pressed just as the last download of it ended.
      _stopping.remove(url);
    });
    try {
      final path = await Media.download(
        url,
        s.files,
        kind,
        stop: () => _stopping.contains(url),
        onProgress: (done) {
          // A step per percent, not a rebuild per chunk.
          if (mounted && (done * 100).floor() > (_downloading[url]! * 100).floor()) {
            setState(() => _downloading[url] = done);
          }
        },
      );
      if (kind == MediaKind.videos && !await Native.canPlay(path)) {
        _unplayable.add(url);
        await Media.forget(path);
        return;
      }
      // Stopped while the last piece came in, or while the video was checked.
      if (_stopping.contains(url)) {
        await Media.forget(path);
        return;
      }
      _pick(kind, path);
    } on DownloadStopped {
      // The user stopped it: nothing to report.
    } on Exception {
      _failed.add(url);
    } finally {
      _downloading.remove(url);
      _stopping.remove(url);
      if (mounted) setState(() {});
    }
  }

  List<Widget> _aerialRows() {
    final c = s.config;
    final scenesOn = Aerials.kinds.where((kind) => !c.aerialsOff.contains(kind)).length;
    return [
      ..._useRow('aerials'),
      _Row(
        'Quality',
        value: _label(_qualities, c.aerialQuality),
        chevron: true,
        onPressed: () => _choose(
          'Quality',
          _qualities,
          () => c.aerialQuality,
          (v) => c.aerialQuality = v,
          enabled: (v) => !v.endsWith('_hdr') || s.aerials.hdr.contains(v),
          note: s.aerials.hdr.length == 2
              ? "HDR films are Dolby Vision. The dock's glass can't blur them."
              : "HDR films are Dolby Vision; this TV can't show the greyed-out ones.",
        ),
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
        note: 'Keeps the last film on the TV (250 MB) so aerials start at once',
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

  /// Choosing a gradient shows it, also when the page was only looked at.
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
            _use('gradient');
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
      _Slider(
        'Spacing',
        value: c.dockSpacing,
        min: 0.25,
        max: 3,
        onChanged: (v) {
          c.dockSpacing = v;
          c.changed();
        },
      ),
      // Past about 220%, a square tile is a circle already.
      _Slider(
        'Corners',
        value: c.tileCorners,
        min: 0,
        max: 2.2,
        onChanged: (v) {
          c.tileCorners = v;
          c.changed();
        },
      ),
      _Slider(
        'Height',
        value: c.dockRoom,
        min: 0.4,
        max: 2.5,
        onChanged: (v) {
          c.dockRoom = v;
          c.changed();
        },
      ),
      _Row(
        'App names',
        note: 'Under the app in focus',
        toggle: c.dockNames,
        onPressed: () {
          c.dockNames = !c.dockNames;
          c.changed();
        },
      ),
      _Row(
        'Glow',
        value: _label(_glows, c.dockGlow),
        chevron: true,
        onPressed: () => _choose(
          'Glow',
          _glows,
          () => c.dockGlow,
          (v) => c.dockGlow = v,
          note: 'How brightly the glass glows behind the app in focus: 1 is the faintest, 3 the brightest.',
        ),
      ),
      _Row('Glass', chevron: true, onPressed: () => _push(_Page('Glass', _glassRows))),
      const _Note('Size, shape, spacing and corners apply in the dock and in All apps.'),
    ];
  }

  /// Rows of things to watch between the dock and all apps: from Plex, and
  /// what other apps share once GTVL may read TV listings.
  List<Widget> _showRows() {
    final c = s.config;
    final plex = s.plex;
    final apps = s.appRows;
    void flip(String id) {
      if (!c.showsOff.remove(id)) c.showsOff.add(id);
      c.changed();
    }

    return [
      const _Header('Plex'),
      _Row(
        plex.signedIn ? 'Account' : 'Sign in',
        value: plex.signedIn ? plex.user : null,
        chevron: true,
        onPressed: plex.signedIn ? () => _push(_Page('Plex account', _plexAccountRows)) : _plexSignIn,
      ),
      for (final (id, label) in Plex.rowNames)
        _Row(label, toggle: !c.showsOff.contains(id), enabled: plex.signedIn, onPressed: () => flip(id)),
      _Note(
        plex.signedIn
            ? 'The rows show between the dock and All apps. OK on a film or episode opens it in Plex.'
            : "Sign in to see what you're watching and what's new on your Plex servers.",
      ),
      const _Header('Other apps'),
      if (!apps.allowed) ...[
        _Row('Allow rows from apps', chevron: true, onPressed: apps.allow),
        const _Note(
          "Shows what you're watching in HBO Max, Netflix and other apps, and the channels they share. "
          'Android asks for permission once.',
        ),
      ] else if (apps.watching.isEmpty && apps.channels.isEmpty)
        const _Note(
          'No app shares a row right now. Rows appear here once you watch something in an app that shares them.',
        )
      else
        for (final row in [...apps.watching, ...apps.channels])
          _Row(
            row.source,
            key: ValueKey(row.id),
            note: row.title == row.source ? 'Picks from the app' : row.title,
            toggle: !c.showsOff.contains(row.id),
            onPressed: () => flip(row.id),
          ),
    ];
  }

  List<Widget> _plexAccountRows() => [
    if (s.plex.user case final user?) _Row('Signed in as', value: user) else const _Row('Signed in'),
    _Row(
      'Sign out',
      onPressed: () {
        s.plex.signOut();
        _back();
      },
    ),
  ];

  /// Shows a code to enter at plex.tv/link, and goes back once Plex has it.
  void _plexSignIn() {
    String? code;
    String? problem;
    final page = _Page(
      'Sign in to Plex',
      () => [
        if (problem != null)
          _Note(problem!)
        else if (code == null)
          const _Note('Asking Plex for a code…')
        else ...[
          const _Note('On your phone or computer, go to plex.tv/link and enter this code:'),
          _Code(code!),
          const _Note("This page closes once you're signed in. Leaving it sooner is fine: signing in still finishes."),
        ],
      ],
    );
    _push(page);
    s.plex.startSignIn().then(
      (given) async {
        if (!mounted || _pages.lastOrNull != page) return;
        setState(() => code = given);
        final done = await s.plex.signIn;
        if (!mounted || _pages.lastOrNull != page) return;
        if (done) {
          _back();
        } else {
          setState(() => problem = 'The code expired. Go back and try again.');
        }
      },
      onError: (Object _) {
        if (mounted) setState(() => problem = "Couldn't reach Plex. Go back and try again.");
      },
    );
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
        'Edges',
        value: _label(_lineWidths, c.lineWidth),
        chevron: true,
        onPressed: () => _choose('Edges', _lineWidths, () => c.lineWidth, (v) => c.lineWidth = v),
      ),
      if (c.lineWidth > 0)
        _Row(
          'Edge brightness',
          value: _label(_lineBrightness, c.lineAlpha),
          chevron: true,
          onPressed: () => _choose('Edge brightness', _lineBrightness, () => c.lineAlpha, (v) => c.lineAlpha = v),
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
        'Aerial location',
        note: 'Where the aerial was filmed, under the clock',
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
      note: id == 'settings' && !shown ? 'Shows when you move into the top bar, so settings stay in reach' : null,
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
    // Back, down and up alike, goes on to PopScope, whose _back puts it down
    // and closes nothing more.
    if (event.logicalKey == LogicalKeyboardKey.goBack) return KeyEventResult.ignored;
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
      // Greyed, but focusable: Right from the rail lands somewhere you can see.
      if (hidden.isEmpty) const _Row('No hidden apps', note: 'Hold OK on an app and choose Hide', enabled: false),
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

  /// The service was off when Buttons opened, and the user was asked once:
  /// later visits leave the asking to the Remapping row.
  static bool _prompted = false;

  /// Asks Android whether the button service is on and which remotes are
  /// connected. With [prompt], asks the user to turn the service on if it is
  /// off, the first time only.
  Future<void> _refreshButtons({bool prompt = false}) async {
    final state = await Native.buttons(knownButtons.keys.toList());
    if (!mounted) return;
    setState(() => _buttons = state);
    if (prompt && !state.on && !_prompted) {
      _prompted = true;
      await showButtonsPrompt(context);
    }
    // The rows came after the level opened: focus the first now.
    if (mounted && FocusManager.instance.primaryFocus == _active) _focusRow();
  }

  /// [action], or while the button service is off, asking to turn it on.
  VoidCallback _whenOn(VoidCallback action) =>
      () => (_buttons?.on ?? false) ? action() : showButtonsPrompt(context);

  /// The remotes connected now and any with changes kept from before, by
  /// id: each one's name and buttons.
  Map<String, (String, Set<String>)> _remotes() {
    final remotes = <String, (String, Set<String>)>{
      for (final remote in _buttons?.remotes ?? const <({String id, String name, List<String> keys, bool used})>[])
        remote.id: (remote.name, {...remote.keys}),
    };
    for (final (id, name, keys) in Remaps(s.config.remotes).saved) {
      final (_, known) = remotes.putIfAbsent(id, () => (name, <String>{}));
      known.addAll(keys);
    }
    return remotes;
  }

  /// A way to find any button, the buttons already changed, then each remote
  /// as a row of its own: TVs list several input devices, most of them no
  /// remote anyone holds, each claiming every button there is. The one that
  /// has sent GTVL keys comes first.
  List<Widget> _buttonRows() {
    final state = _buttons;
    if (state == null) return const [_Note('Looking for remotes…')];
    final remotes = _remotes();
    final remaps = Remaps(s.config.remotes);
    final used = {
      for (final remote in state.remotes)
        if (remote.used) remote.id,
    };
    final changed = [
      for (final MapEntry(key: id, value: (name, keys)) in remotes.entries)
        for (final key in inButtonOrder(keys))
          if (remaps.changes(id, key).isNotEmpty) (id, name, key),
    ];
    int rank(String id) => used.contains(id) ? 0 : (changed.any((button) => button.$1 == id) ? 1 : 2);
    final order = remotes.keys.toList()..sort((a, b) => rank(a) - rank(b));
    return [
      _Row(
        'Remapping',
        value: state.on ? 'On' : 'Off',
        note: state.on ? null : 'Turn on GTVL buttons in Android settings first',
        chevron: true,
        onPressed: state.on ? Native.buttonSettings : () => showButtonsPrompt(context),
      ),
      // First: the quickest way to any button, the ones no remote lists too.
      _Row(
        'Find a button',
        note: 'OK, then press the button on your remote',
        chevron: true,
        onPressed: _whenOn(_findButton),
      ),
      if (changed.isNotEmpty) ...[
        const _Header('Changed'),
        for (final (id, name, key) in changed)
          _buttonRow(id, name, key, note: remotes.length > 1 ? remoteName(name) : null),
      ],
      if (remotes.isNotEmpty) const _Header('Remotes'),
      for (final id in order)
        _Row(
          remoteName(remotes[id]!.$1),
          key: ValueKey('remote $id'),
          note: used.contains(id) ? 'In use' : null,
          chevron: true,
          onPressed: () => _push(_Page(remoteName(remotes[id]!.$1), () => _remoteRows(id))),
        ),
      if (remotes.isEmpty) const _Note('No remote lists its buttons. Find a button by pressing it.'),
      const _Note("OK, the arrows and Power can't be changed."),
    ];
  }

  /// Every button of the remote [id], as Android lists them, and any found on it.
  List<Widget> _remoteRows(String id) {
    final remote = _remotes()[id];
    if (remote == null) return const [_Note("This remote isn't connected.")];
    final (name, keys) = remote;
    return [
      for (final key in inButtonOrder(keys)) _buttonRow(id, name, key),
      const _Note('Android lists every button this kind of remote could have, so some may not be on yours.'),
    ];
  }

  /// A button, with what it does instead, if anything.
  Widget _buttonRow(String remote, String name, String key, {String? note}) {
    final info = buttonInfo(remote, key);
    final changes = Remaps(s.config.remotes).changes(remote, key);
    final value = switch (changes) {
      [] => null,
      [('press', final action)] => _actionLabel(action),
      [(final slot, final action)] => '${_slotLabel(slot)}: ${_actionLabel(action)}',
      _ => '${changes.length} changes',
    };
    return _Row(
      info.label,
      key: ValueKey('$remote $key'),
      value: value == null ? null : _short(value),
      note: note,
      chevron: true,
      onPressed: _whenOn(() => _push(_Page(info.label, () => _slotRows(remote, name, key)))),
    );
  }

  /// What [key] on [remote] does when pressed, held or pressed twice.
  List<Widget> _slotRows(String remote, String name, String key) {
    final info = buttonInfo(remote, key);
    final remaps = Remaps(s.config.remotes);
    // A hold or double press holds the button back until it is clear which
    // it was; then its own press must be made again, or be changed.
    final timed = info.replay || remaps.action(remote, key, 'press') != null;
    return [
      for (final (slot, label) in slots)
        if (!info.holdOnly || slot != 'double')
          _Row(
            label,
            value: _short(_actionLabel(remaps.action(remote, key, slot))),
            chevron: true,
            enabled: slot == 'press' ? !info.holdOnly : timed,
            onPressed: () => _pickAction(remote, name, key, slot, label),
          ),
      if (remaps.changes(remote, key).isNotEmpty)
        _Row(
          'Reset',
          onPressed: () {
            remaps.reset(remote, key);
            _remapsChanged();
            _focusRow();
          },
        ),
      if (info.holdOnly)
        _Note(
          "Pressing ${info.label} always does its usual job, so you can't get stuck. "
          'Only holding it can do something else.',
        ),
      if (!timed)
        _Note(
          'Hold and Double press need Press changed first: after waiting to tell them apart, '
          "GTVL can't send ${info.label}'s own press.",
        ),
      if (timed && !info.holdOnly)
        const _Note('With Double press set, a single press waits a moment in case another press follows.'),
      if (remote == shieldRemote && key == 'MENU')
        const _Note("If the Shield's own Customize menu button setting is in use, leave ☰ alone here."),
    ];
  }

  /// Picks what [slot] of [key] does: its own thing, nothing, an app, or one
  /// of [actionGroups].
  void _pickAction(String remote, String name, String key, String slot, String title) {
    String? current() => Remaps(s.config.remotes).action(remote, key, slot);
    void set(String? action) => _setAction(remote, name, key, slot, action);
    _push(
      _Page(title, () {
        final now = current();
        return [
          _Row('Default', note: 'What the button normally does', checked: now == null, onPressed: () => set(null)),
          _Row('Nothing', checked: now == 'nothing', onPressed: () => set('nothing')),
          _Row(
            'Open an app',
            value: now != null && now.startsWith('app:') ? _short(_actionLabel(now)) : null,
            chevron: true,
            onPressed: () => _choose(
              'Open an app',
              [for (final app in s.apps.all) ('app:${app.package}', app.label)],
              () => current() ?? '',
              set,
            ),
          ),
          for (final (group, actions) in actionGroups)
            _Row(
              group,
              value: actions.any((action) => action.$1 == now) ? _short(_actionLabel(now)) : null,
              chevron: true,
              onPressed: () => _choose(group, actions, () => current() ?? '', set),
            ),
        ];
      }),
    );
  }

  void _setAction(String remote, String name, String key, String slot, String? action) {
    final remaps = Remaps(s.config.remotes)..set(remote, name, key, slot, action);
    // A button whose own press can't be made again loses its hold and double
    // press with its changed press.
    if (slot == 'press' && action == null && !buttonInfo(remote, key).replay) {
      remaps
        ..set(remote, name, key, 'hold', null)
        ..set(remote, name, key, 'double', null);
    }
    _remapsChanged();
  }

  /// Saves the remaps, and hands them to the button service at once.
  void _remapsChanged() {
    s.config.changed();
    Native.remap(s.config.remotes);
  }

  /// [action] as the picker names it: an app by its name; null is Default.
  String _actionLabel(String? action) {
    if (action == null) return 'Default';
    if (action == 'nothing') return 'Nothing';
    if (action.startsWith('app:')) {
      final package = action.substring(4);
      return s.apps.all.where((app) => app.package == package).firstOrNull?.label ?? package;
    }
    for (final (_, actions) in actionGroups) {
      for (final (value, label) in actions) {
        if (value == action) return label;
      }
    }
    return action;
  }

  static String _slotLabel(String slot) => slots.firstWhere((s) => s.$1 == slot).$2;

  /// Waits for a press of any button, then opens that button's page. A button
  /// GTVL didn't list stays listed under its remote from then on.
  void _findButton() {
    var gaveUp = false;
    final page = _Page(
      'Find a button',
      () => [
        _Note(
          gaveUp
              ? 'Nothing was pressed in time. Go back and try again.'
              : 'Press the button on your remote. Back stops looking.',
        ),
      ],
      onClose: Native.stopFinding,
    );
    _push(page);
    Native.findButton().then((found) {
      if (!mounted || _pages.lastOrNull != page) return;
      if (found == null) {
        setState(() => gaveUp = true);
        return;
      }
      Remaps(s.config.remotes).keep(found.remote, found.name, found.key);
      _remapsChanged();
      _refreshButtons();
      // The button's own page takes this one's place.
      setState(_pages.removeLast);
      final label = buttonInfo(found.remote, found.key).label;
      _push(_Page(label, () => _slotRows(found.remote, found.name, found.key)), from: 'Find a button');
    });
  }

  /// The version, its updates from GitHub, and credits.
  List<Widget> _aboutRows() {
    final updates = s.updates;
    final release = updates.release;
    final ready = updates.state == UpdateState.ready && release != null;
    return [
      _Row('Version', value: updates.version),
      const _Header('Updates'),
      _Row(
        ready ? 'Install version ${release.version}' : 'Check for updates',
        value: switch (updates.state) {
          UpdateState.checking => 'Checking…',
          UpdateState.latest => 'Up to date',
          UpdateState.downloading => 'Downloading ${(updates.progress * 100).floor()}%',
          UpdateState.installing => 'Installing…',
          _ => null,
        },
        enabled: !updates.busy,
        onPressed: ready ? updates.install : updates.check,
      ),
      if (ready && !updates.allowed)
        const _Note(
          "The first time, GTVL opens Android's switch for installing apps: turn it on and press Back, and the "
          'update goes ahead.',
        ),
      if (updates.state == UpdateState.failed) _Note(updates.problem ?? 'Something went wrong.'),
      if (release?.notes case final notes? when updates.state != UpdateState.failed) _Note(notes),
      _Row(
        'Automatic updates',
        note: updates.quiet && updates.allowed
            ? 'Checks every few hours, and installs updates while the TV is in standby'
            : 'Checks every few hours, and has updates ready to install here',
        toggle: s.config.autoUpdate,
        onPressed: () => updates.setAuto(!s.config.autoUpdate),
      ),
      const _Header('Credits'),
      const _Note('GTVL: a clean, light home screen for Android TV.'),
      const _Note('Aerial films by Apple. The list of films comes from the Overflight project (Apache-2.0).'),
      const _Note('Text set in Inter, under the SIL Open Font License.'),
    ];
  }
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
                style: i == shown.length - 1
                    ? const TextStyle(color: Look.white, fontSize: 20, fontWeight: FontWeight.w600)
                    : const TextStyle(color: _soft),
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
    required this.badge,
    required this.autofocus,
    required this.onPressed,
    required this.onFocused,
  });

  final _Section section;
  final FocusNode focusNode;
  final double width;
  final bool collapsed;
  final bool selected;

  /// A dot on the icon: something waits in the section.
  final bool badge;
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
      child: AnimatedContainer(
        duration: Look.medium,
        curve: Look.ease,
        width: width,
        height: 46,
        margin: const EdgeInsets.symmetric(vertical: 1),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: focused ? _focusFill : (selected ? _openFill : const Color(0x00FFFFFF)),
          border: Border.all(color: focused ? _focusEdge : const Color(0x00FFFFFF)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 8),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(9)),
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        Icon(section.icon, size: 20, color: focused || selected ? Look.white : _soft),
                        if (badge) const Positioned(right: -2, top: -2, child: Badge()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 13),
                  AnimatedOpacity(
                    opacity: collapsed ? 0 : 1,
                    duration: Look.fast,
                    child: Text(section.label, style: Look.body.copyWith(color: focused ? Look.white : _soft)),
                  ),
                ],
              ),
            ),
            // The section open beside the rail, marked at its edge.
            Positioned(
              left: 0,
              top: 14,
              bottom: 14,
              child: AnimatedOpacity(
                opacity: selected && collapsed ? 1 : 0,
                duration: Look.fast,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(color: Look.white, borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
          ],
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
    this.onRight,
    this.active = false,
    this.enabled = true,
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

  /// What Right does on a chevron row instead of OK's action: opens the
  /// level without choosing what the row stands for.
  final VoidCallback? onRight;
  final bool active;

  /// False greys the row out: it can still be focused, to read why, but does nothing.
  final bool enabled;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) {
    final column = _Column.of(context);
    if (column?.folded ?? false) return _folded(column!.opened == label);
    return Pressable(
      onPressed: enabled ? onPressed : null,
      onLongPress: enabled ? onLongPress : null,
      onKey: (event) {
        final custom = onKey?.call(event) ?? KeyEventResult.ignored;
        if (custom != KeyEventResult.ignored) return custom;
        if (enabled && chevron && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
          (onRight ?? onPressed)?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (context, focused) => AnimatedContainer(
        duration: Look.fast,
        curve: Look.ease,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: focused ? _focusFill : (active ? _openFill : const Color(0x00FFFFFF)),
          border: Border.all(color: focused ? _focusEdge : const Color(0x00FFFFFF)),
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
                  Text(
                    label,
                    style: Look.body.copyWith(
                      color: !enabled ? _quiet : (focused ? Look.white : const Color(0xE6FFFFFF)),
                    ),
                  ),
                  if (note != null) Prose(note!, style: Look.small.copyWith(color: _noteColor)),
                ],
              ),
            ),
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(value!, style: Look.value.copyWith(color: focused ? Look.white : _soft)),
              ),
            if (toggle != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Toggle(on: toggle!),
              ),
            if (checked)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Icon(Icons.check_rounded, size: 20, color: Look.white),
              ),
            if (chevron) Icon(Icons.chevron_right_rounded, size: 20, color: focused ? _soft : _quiet),
          ],
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
            style: Look.small.copyWith(color: _quiet, fontWeight: FontWeight.w600, letterSpacing: 0.4),
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
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Prose(text, style: Look.small.copyWith(color: _noteColor)),
        );
}

/// [thumbs] two to a row, each row its own item in the list, so previews
/// load as they scroll into view.
List<Widget> _grid(List<Widget> thumbs) => [
  for (var i = 0; i < thumbs.length; i += 2) _ThumbRow(thumbs[i], i + 1 < thumbs.length ? thumbs[i + 1] : null),
];

/// Two previews side by side. Hidden in folded columns.
class _ThumbRow extends StatelessWidget {
  const _ThumbRow(this.left, this.right);

  final Widget left;
  final Widget? right;

  @override
  Widget build(BuildContext context) => (_Column.of(context)?.folded ?? false)
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 14),
              Expanded(child: right ?? const SizedBox.shrink()),
            ],
          ),
        );
}

/// A picture or video to pick: a 16:9 preview with its name below, and a
/// check while picked. Focus lifts it a little and rings it in white.
class _Thumb extends StatelessWidget {
  const _Thumb(
    this.label, {
    super.key,
    this.picture,
    this.folder = false,
    this.checked = false,
    this.status,
    this.progress,
    this.onPressed,
  });

  final String label;

  /// The preview, filling the frame; empty while it loads.
  final Widget? picture;

  /// Stands for everything in a folder.
  final bool folder;
  final bool checked;

  /// Said over the preview, e.g. "Downloading", with [progress] (0 to 1) as
  /// a line along its foot.
  final String? status;
  final double? progress;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Pressable(
    onPressed: onPressed,
    builder: (context, focused) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedScale(
          scale: focused ? 1.04 : 1,
          duration: Look.fast,
          curve: Look.ease,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: AnimatedContainer(
              duration: Look.fast,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(10)),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: focused ? Look.white : Look.hairline, width: focused ? 2 : 1),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ?picture,
                  if (folder) const Positioned(left: 8, bottom: 8, child: _Badge(Icons.folder_outlined)),
                  if (status != null)
                    ColoredBox(
                      color: const Color(0x99000000),
                      child: Center(
                        child: Text(status!, style: Look.small.copyWith(color: Look.white)),
                      ),
                    ),
                  if (progress != null)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress!.clamp(0.0, 1.0),
                        child: const SizedBox(height: 3, child: ColoredBox(color: Look.white)),
                      ),
                    ),
                  if (checked) const Positioned(top: 8, right: 8, child: _Badge(Icons.check_rounded, filled: true)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Look.small.copyWith(color: focused ? Look.white : _soft),
          ),
        ),
      ],
    ),
  );
}

/// A small round mark on a preview: white with a dark icon when [filled].
class _Badge extends StatelessWidget {
  const _Badge(this.icon, {this.filled = false});

  final IconData icon;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(shape: BoxShape.circle, color: filled ? Look.white : const Color(0x99000000)),
    child: Icon(icon, size: 14, color: filled ? const Color(0xFF1C1C1E) : Look.white),
  );
}

/// Fades an image in once it has decoded, unless it was there at once.
Widget _fadeIn(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) => wasSynchronouslyLoaded
    ? child
    : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: Look.medium, child: child);

/// Nothing, where an image could not load.
Widget _blank(BuildContext context, Object error, StackTrace? stackTrace) => const SizedBox.shrink();

/// A sign-in code, large enough to read across the room. Hidden in folded
/// columns.
class _Code extends StatelessWidget {
  const _Code(this.code);

  final String code;

  @override
  Widget build(BuildContext context) => (_Column.of(context)?.folded ?? false)
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          child: Text(code, style: Look.title.copyWith(fontSize: 44, letterSpacing: 10)),
        );
}

/// A setting that slides: Left and Right change it a step at a time, and
/// held they keep going; the dock behind shows each step at once. It reads
/// as a share of the usual value (1, today's look), which a tick marks.
/// Left adjusts here, so Back is the way out.
class _Slider extends StatelessWidget {
  const _Slider(this.label, {required this.value, required this.min, required this.max, required this.onChanged});

  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;

  static const _step = 0.05;

  @override
  Widget build(BuildContext context) {
    final percent = '${(value * 100).round()}%';
    if (_Column.of(context)?.folded ?? false) return _Row(label, value: percent);
    return Pressable(
      onKey: (event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => -1,
          LogicalKeyboardKey.arrowRight => 1,
          _ => 0,
        };
        if (direction == 0) return KeyEventResult.ignored;
        final next = ((value + direction * _step) / _step).round() * _step;
        onChanged(double.parse(next.clamp(min, max).toStringAsFixed(2)));
        return KeyEventResult.handled;
      },
      builder: (context, focused) => AnimatedContainer(
        duration: Look.fast,
        curve: Look.ease,
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.fromLTRB(13, 9, 13, 12),
        decoration: BoxDecoration(
          color: focused ? _focusFill : const Color(0x00FFFFFF),
          border: Border.all(color: focused ? _focusEdge : const Color(0x00FFFFFF)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(label, style: Look.body.copyWith(color: focused ? Look.white : const Color(0xE6FFFFFF))),
                ),
                // Arrows either side of the value while focused: Left and Right change it.
                // Their room is kept, so nothing moves as they come and go.
                AnimatedOpacity(
                  opacity: focused ? 1 : 0,
                  duration: Look.fast,
                  child: const Icon(Icons.chevron_left_rounded, size: 18, color: _soft),
                ),
                Text(
                  percent,
                  style: Look.value.copyWith(color: focused ? Look.white : _soft, fontFeatures: Look.figures),
                ),
                AnimatedOpacity(
                  opacity: focused ? 1 : 0,
                  duration: Look.fast,
                  child: const Icon(Icons.chevron_right_rounded, size: 18, color: _soft),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _Track(at: (value - min) / (max - min), usual: (1 - min) / (max - min), focused: focused),
          ],
        ),
      ),
    );
  }
}

/// A slider's line: filled up to [at] (0 to 1), a knob there while focused,
/// and a tick at the usual value.
class _Track extends StatelessWidget {
  const _Track({required this.at, required this.usual, required this.focused});

  final double at, usual;
  final bool focused;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 18,
    child: LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.centerLeft,
          children: [
            Container(
              height: 5,
              decoration: BoxDecoration(color: const Color(0x33FFFFFF), borderRadius: BorderRadius.circular(3)),
            ),
            Container(
              width: width * at.clamp(0.0, 1.0),
              height: 5,
              decoration: BoxDecoration(color: focused ? Look.white : _soft, borderRadius: BorderRadius.circular(3)),
            ),
            Positioned(
              left: width * usual - 1,
              child: Container(width: 2, height: 14, color: _quiet),
            ),
            if (focused)
              Positioned(
                left: width * at.clamp(0.0, 1.0) - 9,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: Look.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0x4D000000)),
                    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2))],
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// A thin bar at the right edge of a long level, showing where in it you
/// are: while it scrolls, and for a moment when it opens.
class _ScrollCue extends StatefulWidget {
  const _ScrollCue({required this.child});

  final Widget child;

  @override
  State<_ScrollCue> createState() => _ScrollCueState();
}

class _ScrollCueState extends State<_ScrollCue> {
  ScrollMetrics? _metrics;
  bool _shown = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    setState(() {
      _metrics = metrics;
      _shown = metrics.maxScrollExtent > 0;
    });
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _shown = false);
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (note) => note.depth == 0 && _onScroll(note.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (note) => note.depth == 0 && _onScroll(note.metrics),
        child: Stack(
          children: [
            widget.child,
            if (metrics != null && metrics.maxScrollExtent > 0)
              Builder(
                builder: (context) {
                  final view = metrics.viewportDimension - 16;
                  final whole = metrics.maxScrollExtent + metrics.viewportDimension;
                  final length = (view * metrics.viewportDimension / whole).clamp(28.0, view);
                  final at = (metrics.pixels / metrics.maxScrollExtent).clamp(0.0, 1.0);
                  return Positioned(
                    right: 3,
                    top: 8 + (view - length) * at,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _shown ? 1 : 0,
                        duration: Look.medium,
                        child: Container(
                          width: 3,
                          height: length,
                          decoration: BoxDecoration(
                            color: const Color(0x66FFFFFF),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
