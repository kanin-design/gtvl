import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'menu.dart';
import 'native.dart';
import 'services.dart';
import 'settings.dart';
import 'shows.dart';
import 'tile.dart';
import 'ui.dart';
import 'wallpaper.dart';

/// Sizes derived from the screen, so the layout fits any TV.
class _Geometry {
  _Geometry(
    Size size, {
    required String dockSize,
    required this.square,
    double spacing = 1,
    double corners = 1,
    double room = 1,
    bool names = false,
  }) : width = size.width,
       height = size.height,
       pad = (size.width * 0.04).roundToDouble(),
       columns = (square ? _squareColumns : _columns)[dockSize] ?? (square ? 13 : 8) {
    // Tiles keep their size whatever the spacing: it widens or narrows only the gaps.
    baseGap = (width * 0.014).roundToDouble();
    gap = (baseGap * spacing).roundToDouble();
    tileWidth = (width - 2 * pad - (columns - 1) * baseGap) / columns;
    tileHeight = square ? tileWidth : tileWidth * 9 / 16;
    // All apps: as many columns as fit at that size and spacing, from the left.
    gridColumns = ((width - 2 * pad + gap) / (tileWidth + gap)).floor().clamp(1, 99);
    gridEnd = width - pad - gridColumns * tileWidth - (gridColumns - 1) * gap;
    radius = ((square ? tileWidth * 0.225 : 10) * corners).clamp(0, tileHeight / 2).roundToDouble();
    // Room above and below a tile for its focus lift and shadow, and its name when shown.
    dockHeight = tileHeight * (1 + 0.36 * room) + (names ? labelHeight : 0);
    dockIdle = height - dockHeight - height * 0.07;
    dockTop = height * 0.06;
    gridTop = dockTop + dockHeight + height * 0.02;
  }

  /// Tiles per row, by dock size: smaller tiles fit more. Squares are
  /// narrower, so more of them fit at about the same height.
  static const _columns = {'xs': 12, 's': 10, 'm': 8, 'l': 6, 'xl': 5};
  static const _squareColumns = {'xs': 20, 's': 16, 'm': 13, 'l': 10, 'xl': 8};
  static const labelHeight = 26.0;
  final bool square;
  final int columns;
  late final int gridColumns;
  final double width, height, pad;

  /// The gap at medium spacing, which sets the tiles' size and the rows of
  /// shows; [gap] is the one the user chose, between apps.
  late final double baseGap, gap;

  /// The all-apps grid's padding on the right, so its tiles keep their size.
  late final double gridEnd;
  late final double tileWidth, tileHeight, radius, dockHeight, dockIdle, dockTop, gridTop;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late final Services s = Services.of(context);

  /// 0: home, with the dock near the bottom. 1: all apps, the dock at the top.
  late final _page = AnimationController(vsync: this, duration: Look.medium);
  late final _eased = CurvedAnimation(parent: _page, curve: Curves.easeInOutCubic);
  final _dock = FocusScopeNode(debugLabel: 'dock');
  final _grid = FocusScopeNode(debugLabel: 'grid');
  final _gridScroll = ScrollController();
  final _bar = FocusScopeNode(debugLabel: 'bar');

  /// The top bar is on screen: while it has focus.
  final _barShown = ValueNotifier(false);

  /// The dock app being moved, if any.
  String? _moving;

  /// The glow in the dock's glass, and the dock app it is under, by package.
  late final _molten = _Molten(this);
  String? _glowing;
  StreamSubscription<Object?>? _homeKey, _opens;

  @override
  void initState() {
    super.initState();
    // Home pressed while already home: close menus, back to the dock.
    _homeKey = Native.events.where((event) => event['type'] == 'home').listen((_) => _goHome(closeMenus: true));
    // A remapped button asking for settings or all apps.
    _opens = Native.events.where((event) => event['type'] == 'open').listen((event) {
      if (!mounted) return;
      _goHome(closeMenus: true);
      switch (event['what']) {
        case 'settings':
          showSettings(context);
        case 'apps':
          _enter(_grid);
      }
    });
  }

  @override
  void dispose() {
    _homeKey?.cancel();
    _opens?.cancel();
    _eased.dispose();
    _page.dispose();
    _dock.dispose();
    _grid.dispose();
    _gridScroll.dispose();
    _bar.dispose();
    _barShown.dispose();
    _molten.dispose();
    super.dispose();
  }

  /// Focuses the item last focused in [scope], or its top-left one; with
  /// [first], always its top-left one, once the frame that brings it in view
  /// has laid it out.
  void _enter(FocusScopeNode scope, {bool first = false}) {
    if (!first) {
      (scope.focusedChild ?? _topLeft(scope))?.requestFocus();
      return;
    }
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => _topLeft(scope)?.requestFocus())
      ..scheduleFrame();
  }

  /// [scope]'s item nearest the top left, as the eye reads it, among those
  /// on screen across: a row of shows scrolled sideways keeps cards built
  /// out of sight. The focus tree's own order is the order items were built
  /// in: rows of shows load after the apps below them.
  FocusNode? _topLeft(FocusScopeNode scope) {
    final width = MediaQuery.sizeOf(context).width;
    final nodes = scope.traversalDescendants;
    final across = nodes.where((node) => node.rect.left >= 0 && node.rect.right <= width);
    return (across.isEmpty ? nodes : across).fold<FocusNode?>(null, (best, node) {
      if (best == null) return node;
      final (a, b) = (node.rect, best.rect);
      if ((a.top - b.top).abs() > 1) return a.top < b.top ? node : best;
      return a.left < b.left ? node : best;
    });
  }

  /// Focuses [package]'s tile in [scope], if it is built.
  void _focusTile(FocusScopeNode scope, String package) {
    final node = scope.traversalDescendants
        .where((node) => node.context?.findAncestorWidgetOfExactType<AppTile>()?.app.package == package)
        .firstOrNull;
    node?.requestFocus();
    if (node?.context case final context?) reveal(context);
  }

  void _goHome({bool closeMenus = false}) {
    if (closeMenus) Navigator.of(context).popUntil((route) => route.isFirst);
    if (_moving != null) setState(() => _moving = null);
    _enter(s.apps.dock.isEmpty ? _grid : _dock);
  }

  static bool _isPress(KeyEvent event) => event is KeyDownEvent || event is KeyRepeatEvent;

  /// The home screen is the top screen. A tile built behind a menu, as a
  /// settings change can rebuild them, must not take the menu's focus.
  bool get _onTop => ModalRoute.isCurrentOf(context) ?? true;

  KeyEventResult _onDockKey(FocusNode node, KeyEvent event) {
    if (_moving != null || !_isPress(event)) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        // Up goes into the top bar, always at its first icon (the gear, unless moved).
        if (event is KeyDownEvent) _enter(_bar, first: true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        // Down always starts at the top: the first row of shows, else the first app.
        if (event is KeyDownEvent) {
          if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
          _enter(_grid, first: true);
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    if (!_isPress(event) || event.logicalKey != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    // Up from the top row goes back to the dock; with no apps in it, to the top bar.
    final moved = FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up) ?? false;
    if (!moved && event is KeyDownEvent) {
      if (s.apps.dock.isEmpty) {
        _enter(_bar, first: true);
      } else {
        _enter(_dock);
      }
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onBarKey(FocusNode node, KeyEvent event) {
    if (!_isPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) _enter(s.apps.dock.isEmpty ? _grid : _dock);
      return KeyEventResult.handled;
    }
    return event.logicalKey == LogicalKeyboardKey.arrowUp ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Keys for the dock app being moved: Left and Right move it, OK or Back puts it down.
  KeyEventResult _onMoveKey(KeyEvent event) {
    // Back, down and up alike, goes on to PopScope, which puts it down.
    if (event.logicalKey == LogicalKeyboardKey.goBack) return KeyEventResult.ignored;
    if (!_isPress(event)) return KeyEventResult.handled;
    final package = _moving!;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        s.apps.move(package, -1);
      case LogicalKeyboardKey.arrowRight:
        s.apps.move(package, 1);
      case LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowDown:
        break;
      default:
        if (event is KeyDownEvent) setState(() => _moving = null);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null && focused.mounted) reveal(focused);
    });
    return KeyEventResult.handled;
  }

  void _onBack() {
    if (_moving != null) {
      setState(() => _moving = null);
    } else if (!_dock.hasFocus) {
      _goHome();
    }
  }

  /// Opens [app]; if Android won't, says so.
  Future<void> _launch(AppInfo app) async {
    if (!await Native.launch(app.package)) s.notice.show("Couldn't open ${app.label}");
  }

  /// Opens [item] of a row from [source]; if it won't open, says so.
  Future<void> _open(ShowItem item, String source) async {
    if (!await Native.open(item.link, package: item.app)) s.notice.show("Couldn't open $source");
  }

  /// The app menu. An app that leaves its list there (hidden, or moved
  /// between the dock and all apps) hands focus to the app now in its place.
  Future<void> _menu(AppInfo app) async {
    final inDock = s.apps.inDock(app.package);
    List<AppInfo> list() => inDock ? s.apps.dock : s.apps.others;
    final at = list().indexWhere((other) => other.package == app.package);
    await showAppMenu(context, app, onMove: inDock ? () => setState(() => _moving = app.package) : null);
    final now = list();
    if (!mounted || at < 0 || now.isEmpty || now.any((other) => other.package == app.package)) return;
    final next = now[at.clamp(0, now.length - 1)].package;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _onTop) _focusTile(inDock ? _dock : _grid, next);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _onBack();
    },
    // Rebuilds on config changes too, so a new dock size applies at once.
    child: ListenableBuilder(
      listenable: s.config,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final c = s.config;
          final g = _Geometry(
            box.biggest,
            dockSize: c.dockSize,
            square: c.tileShape == 'square',
            spacing: c.dockSpacing,
            corners: c.tileCorners,
            room: c.dockRoom,
            names: c.dockNames,
          );
          final eased = _eased;
          return Stack(
            fit: StackFit.expand,
            children: [
              const Wallpaper(),
              // A light vignette under the dock, so it and its names hold on bright films.
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x00000000), Color(0x00000000), Color(0x40000000)],
                      stops: [0, 0.5, 1],
                    ),
                  ),
                ),
              ),
              // Dims the wallpaper behind the app grid.
              IgnorePointer(
                child: FadeTransition(
                  opacity: eased,
                  child: const ColoredBox(color: Color(0x73000000)),
                ),
              ),
              ListenableBuilder(
                listenable: Listenable.merge([s.apps, s.config, s.plex, s.appRows]),
                builder: (context, _) => Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: g.gridTop,
                      bottom: 0,
                      child: AnimatedBuilder(
                        animation: eased,
                        child: RepaintBoundary(child: _gridView(g)),
                        // Below the screen while home; not painted at all until it moves.
                        builder: (context, grid) => Opacity(
                          opacity: eased.value == 0 ? 0 : 1,
                          child: Transform.translate(
                            offset: Offset(0, (1 - eased.value) * (g.height - g.gridTop)),
                            child: grid,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: g.dockIdle,
                      height: g.dockHeight,
                      child: AnimatedBuilder(
                        animation: eased,
                        child: RepaintBoundary(child: _dockBar(g)),
                        builder: (context, dock) =>
                            Transform.translate(offset: Offset(0, eased.value * (g.dockTop - g.dockIdle)), child: dock),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: g.dockIdle - 48,
                      child: Center(
                        child: ValueListenableBuilder<String?>(
                          valueListenable: s.notice,
                          builder: (context, notice, _) => AnimatedSwitcher(
                            duration: Look.medium,
                            switchInCurve: Look.ease,
                            switchOutCurve: Curves.easeIn,
                            child: switch ((_moving, notice)) {
                              (_?, _) => const Pill(
                                'Left and Right move the app · OK when done',
                                key: ValueKey('move'),
                              ),
                              (_, final text?) => Pill(text, key: ValueKey(text)),
                              _ => const SizedBox.shrink(),
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // A shade behind the top bar while it shows, so the clock and icons read on bright films.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: g.height * 0.32,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _barShown,
                    builder: (context, shown, shade) =>
                        AnimatedOpacity(opacity: shown ? 1 : 0, duration: Look.medium, child: shade),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x80000000), Color(0x00000000)],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(left: g.pad - 13, right: g.pad, top: g.height * 0.05, child: _topBar()),
            ],
          );
        },
      ),
    ),
  );

  Widget _dockBar(_Geometry g) {
    final apps = s.apps.dock;
    final c = s.config;
    // The app the glow is under may have moved along, or another app gone.
    final glowing = apps.indexWhere((app) => app.package == _glowing);
    if (glowing >= 0) _molten.focus(glowing);
    final names = c.dockNames ? _Geometry.labelHeight : 0.0;
    final (first, step) = _centres(g, apps.length, c.dockAlign);
    return FocusScope(
      node: _dock,
      onKeyEvent: _onDockKey,
      onFocusChange: (focused) {
        if (focused) {
          _page.reverse();
        } else {
          _glowing = null;
          _molten.focus(null);
        }
      },
      child: Glass(
        sigma: c.glassBlur,
        tint: Color(c.glassTint).withValues(alpha: c.glassTintAlpha),
        vibrancy: 1.35,
        child: CustomPaint(
          painter: _BandLight(line: c.lineWidth, alpha: c.lineAlpha),
          child: apps.isEmpty
              ? Center(
                  child: Text(
                    s.apps.loaded ? 'Hold OK on an app and choose Favourite to add it here' : '',
                    style: Look.value,
                  ),
                )
              : FocusTraversalGroup(
                  policy: smoothTraversal,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(horizontal: g.pad - g.gap / 2),
                    // At least the screen's width, so apps that fit can spread across it.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: g.width - 2 * g.pad + g.gap),
                      // The glow, behind the apps and moving along with them.
                      child: CustomPaint(
                        painter: _MoltenPainter(
                          _molten,
                          first: first,
                          step: step,
                          tile: Size(g.tileWidth, g.tileHeight),
                          radius: g.radius,
                          raise: names / 2,
                          ratio: MediaQuery.devicePixelRatioOf(context),
                        ),
                        child: Row(
                          mainAxisAlignment: _arrangements[c.dockAlign] ?? MainAxisAlignment.start,
                          children: [
                            for (var i = 0; i < apps.length; i++)
                              Padding(
                                key: ValueKey(apps[i].package),
                                padding: EdgeInsets.symmetric(horizontal: g.gap / 2),
                                child: SizedBox(
                                  width: g.tileWidth,
                                  height: g.tileHeight + names,
                                  child: AppTile(
                                    app: apps[i],
                                    square: g.square,
                                    radius: g.radius,
                                    label: c.dockNames,
                                    autofocus: i == 0 && _onTop,
                                    moving: _moving == apps[i].package,
                                    onKey: _moving == apps[i].package ? _onMoveKey : null,
                                    onLaunch: () => _launch(apps[i]),
                                    onMenu: () => _menu(apps[i]),
                                    glow: _molten,
                                    index: i,
                                    onDown: _molten.press,
                                    onFocusChange: (focused) {
                                      if (!focused) return;
                                      _glowing = apps[i].package;
                                      _molten.focus(i);
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  /// Where the dock's apps sit, as the centre of the first and the distance
  /// from one centre to the next, along the row of [count] apps as its
  /// "arrange" setting spreads them.
  (double, double) _centres(_Geometry g, int count, String arrange) {
    final cell = g.tileWidth + g.gap;
    final free = count == 0 ? 0.0 : math.max(0.0, g.width - 2 * g.pad + g.gap - count * cell);
    return switch (arrange) {
      'center' => (free / 2 + cell / 2, cell),
      'evenly' => (free / (count + 1) + cell / 2, cell + free / (count + 1)),
      'between' when count > 1 => (cell / 2, cell + free / (count - 1)),
      _ => (cell / 2, cell),
    };
  }

  /// How the dock spreads apps that fit, by its "arrange" setting.
  static const _arrangements = {
    'center': MainAxisAlignment.center,
    'evenly': MainAxisAlignment.spaceEvenly,
    'between': MainAxisAlignment.spaceBetween,
  };

  /// Below the dock: rows of things to watch, then every other app.
  Widget _gridView(_Geometry g) {
    final apps = s.apps.others;
    // What is being watched first, Plex and then each app; then what is new; then apps' own channels.
    final plex = {for (final row in s.plex.rows) row.id: row};
    final rows = [
      ?plex['plex.continue'],
      ...s.appRows.watching,
      ?plex['plex.recent'],
      ...s.appRows.channels,
    ].where((row) => row.items.isNotEmpty && !s.config.showsOff.contains(row.id)).toList();
    return FocusScope(
      node: _grid,
      onKeyEvent: _onGridKey,
      onFocusChange: (focused) {
        if (focused) _page.forward();
      },
      child: FocusTraversalGroup(
        policy: smoothTraversal,
        child: CustomScrollView(
          controller: _gridScroll,
          slivers: [
            for (final row in rows)
              // Keyed here, among the slivers: a row added above keeps those below as they are.
              SliverToBoxAdapter(
                key: ValueKey(row.id),
                child: ShowRow(
                  row: row,
                  pad: g.pad,
                  gap: g.baseGap,
                  cardWidth: (g.width - 2 * g.pad - 3 * g.baseGap) / 4,
                  onOpen: (item) => _open(item, row.source),
                ),
              ),
            if (rows.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(g.pad, 6, g.pad, 0),
                  child: Text('All apps', style: Look.label.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(g.pad, 18, g.gridEnd, 60),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: g.gridColumns,
                  crossAxisSpacing: g.gap,
                  mainAxisSpacing: g.gap * 0.6,
                  childAspectRatio: g.tileWidth / (g.tileHeight + _Geometry.labelHeight),
                ),
                delegate: SliverChildBuilderDelegate(
                  childCount: apps.length,
                  // Tiles keep their place in the focus tree when apps before them come or go.
                  findChildIndexCallback: (key) {
                    final i = key is ValueKey<String> ? apps.indexWhere((app) => app.package == key.value) : -1;
                    return i < 0 ? null : i;
                  },
                  (context, i) => AppTile(
                    key: ValueKey(apps[i].package),
                    app: apps[i],
                    square: g.square,
                    radius: g.radius,
                    label: true,
                    autofocus: i == 0 && s.apps.dock.isEmpty && _onTop,
                    onKey: (event) => rowEnd(
                      event,
                      first: i % g.gridColumns == 0,
                      last: i % g.gridColumns == g.gridColumns - 1 || i == apps.length - 1,
                    ),
                    onLaunch: () => _launch(apps[i]),
                    onMenu: () => _menu(apps[i]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() => FocusScope(
    node: _bar,
    onKeyEvent: _onBarKey,
    onFocusChange: (focused) => _barShown.value = focused,
    child: ValueListenableBuilder<bool>(
      valueListenable: _barShown,
      builder: (context, shown, bar) => AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: Look.fast,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : const Offset(0, -0.3),
          duration: Look.medium,
          curve: Look.ease,
          child: bar,
        ),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([s.config, s.status, s.updates]),
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final id in s.config.topIcons) ?_topIcon(id),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Level with the icons' middles.
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Clock(h24: s.config.clock24),
                ),
                ValueListenableBuilder<String?>(
                  valueListenable: s.caption,
                  builder: (context, caption, _) => caption == null || caption.isEmpty || !s.config.showCaption
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(caption, style: Look.caption),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget? _topIcon(String id) {
    final hidden = s.config.topHidden.contains(id);
    switch (id) {
      case 'settings':
        // Always there so Up can reach it: a hidden gear shows only while
        // focused, so settings can never be locked away.
        return TopIcon(
          key: ValueKey(id),
          icon: Icons.settings_outlined,
          collapsed: hidden,
          // An update waits in settings, under About.
          badge: s.updates.waiting,
          onPressed: () => showSettings(context),
        );
      case 'network' when !hidden:
        return TopIcon(
          key: ValueKey(id),
          icon: s.status.networkIcon,
          onPressed: () => Native.openSettings('android.settings.WIFI_SETTINGS'),
        );
      case 'vpn' when !hidden:
        final app = s.status.vpnApp;
        if (app == null) return null;
        return TopIcon(
          key: ValueKey(id),
          icon: s.status.vpn ? Icons.vpn_lock : Icons.vpn_lock_outlined,
          dim: !s.status.vpn,
          onPressed: () async {
            if (!await Native.launch(app.package)) s.notice.show("Couldn't open ${app.name}");
          },
        );
    }
    return null;
  }
}

/// A top-bar icon. Focus brightens it and sets it on a soft round light.
class TopIcon extends StatelessWidget {
  const TopIcon({
    super.key,
    required this.icon,
    required this.onPressed,
    this.dim = false,
    this.collapsed = false,
    this.badge = false,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Drawn fainter, e.g. a VPN that is off.
  final bool dim;

  /// Takes no space until focused.
  final bool collapsed;

  /// A dot on its corner: something waits behind it.
  final bool badge;

  @override
  Widget build(BuildContext context) => Pressable(
    onPressed: onPressed,
    builder: (context, focused) {
      final icon = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: AnimatedScale(
          scale: focused ? 1.08 : 1,
          duration: Look.fast,
          curve: Look.ease,
          child: AnimatedContainer(
            duration: Look.fast,
            curve: Look.ease,
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: focused ? const Color(0x38FFFFFF) : const Color(0x00FFFFFF),
              border: Border.all(color: focused ? Look.focusEdge : const Color(0x00FFFFFF)),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Icon(
                  this.icon,
                  size: 22,
                  color: Look.white.withValues(alpha: focused ? 1 : (dim ? 0.55 : 0.85)),
                  shadows: focused ? null : Look.shadow,
                ),
                if (badge) const Positioned(right: 7, top: 7, child: Badge()),
              ],
            ),
          ),
        ),
      );
      if (!collapsed) return icon;
      return ClipRect(
        child: Align(alignment: Alignment.centerLeft, widthFactor: focused ? 1 : 0, child: icon),
      );
    },
  );
}

/// The time, updated on the minute.
class Clock extends StatefulWidget {
  const Clock({super.key, required this.h24});

  final bool h24;

  @override
  State<Clock> createState() => _ClockState();
}

class _ClockState extends State<Clock> {
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

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final hour = widget.h24 ? now.hour.toString().padLeft(2, '0') : '${(now.hour + 11) % 12 + 1}';
    return Text.rich(
      TextSpan(
        text: '$hour:${now.minute.toString().padLeft(2, '0')}',
        children: [
          if (!widget.h24)
            TextSpan(
              text: now.hour < 12 ? ' am' : ' pm',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xCCFFFFFF)),
            ),
        ],
      ),
      style: Look.clock,
    );
  }
}

/// Light on the dock's glass, from above: an edge along its top, brightest a
/// third of the way across and fading toward the sides; a soft glow inside,
/// just under it; and a fainter edge along its bottom. [line] is the edges'
/// thickness (0 for none) and [alpha] their usual strength.
class _BandLight extends CustomPainter {
  _BandLight({required this.line, required this.alpha});

  final double line, alpha;

  static Color _white(double alpha) => Color.fromRGBO(255, 255, 255, alpha.clamp(0.0, 1.0));

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Rect.fromLTWH(0, 0, size.width, size.height * 0.45);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_white(0.07), _white(0)],
        ).createShader(glow),
    );
    if (line <= 0) return;
    final top = Rect.fromLTWH(0, 0, size.width, line);
    canvas.drawRect(
      top,
      Paint()
        ..shader = LinearGradient(
          colors: [_white(alpha * 0.8), _white(alpha * 2.6), _white(alpha * 1.6), _white(alpha * 0.8)],
          stops: const [0, 0.32, 0.68, 1],
        ).createShader(top),
    );
    canvas.drawRect(Rect.fromLTWH(0, size.height - line, size.width, line), Paint()..color = _white(alpha * 0.6));
  }

  @override
  bool shouldRepaint(_BandLight old) => old.line != line || old.alpha != alpha;
}

/// The dock's light: a hot glow in the glass behind the app in focus. It
/// flows after focus to the next app, leaves an ember where it was that cools
/// to red as it fades, and cools away when focus leaves the dock. It ticks
/// only while something changes.
class _Molten extends ChangeNotifier implements ValueListenable<Glow?> {
  _Molten(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  Duration? _last;
  double _at = 0, _to = 0, _heat = 0, _hot = 0;

  /// How fast the glow flows, in apps a second.
  double speed = 0;

  /// Embers left where the glow was, as (place, heat).
  final embers = <(double, double)>[];

  @override
  Glow? get value => _heat < 0.005 ? null : Glow(_at, _heat);

  /// OK is down on the app in focus: the glow flares while it is.
  void press(bool down) {
    if (_hot == 0) return;
    _hot = down ? 1.35 : 1;
    _start();
  }

  /// Focus is on the dock app at [index], or has left the dock (null).
  void focus(int? index) {
    final hot = index == null ? 0.0 : 1.0;
    final to = index?.toDouble() ?? _to;
    if (to == _to && hot == _hot) return;
    if (index != null) {
      if (_heat < 0.05) {
        // Cold: it lights up where focus is, rather than flowing there.
        _at = to;
      } else if ((to - _to).abs() > 0.5) {
        embers.add((_at, _heat * 0.85));
        if (embers.length > 3) embers.removeAt(0);
      }
      _to = to;
    }
    _hot = hot;
    _start();
  }

  void _start() {
    if (_ticker.isActive) return;
    _last = null;
    _ticker.start();
  }

  void _tick(Duration now) {
    final dt = _last == null ? 1 / 60 : (now - _last!).inMicroseconds / 1e6;
    _last = now;
    final was = _at;
    _at += (_to - _at) * (1 - math.exp(-dt * 16));
    speed = dt > 0 ? (_at - was) / dt : 0;
    // Heats quickly, cools slowly.
    _heat += (_hot - _heat) * (1 - math.exp(-dt * (_hot > _heat ? 12 : 3.5)));
    for (var i = embers.length - 1; i >= 0; i--) {
      final (at, heat) = embers[i];
      final cooler = heat * math.exp(-dt * 4.5);
      if (cooler < 0.02) {
        embers.removeAt(i);
      } else {
        embers[i] = (at, cooler);
      }
    }
    if ((_to - _at).abs() < 0.001 && (_hot - _heat).abs() < 0.002 && embers.isEmpty) {
      _at = _to;
      _heat = _hot;
      speed = 0;
      _ticker.stop();
    }
    notifyListeners();
  }

  /// The halo round the lifted app, blurred once for its size (see [_Halo]).
  _Halo? _halo;

  _Halo halo(Size tile, double radius, double ratio) {
    if (_halo case final halo? when halo.tile == tile && halo.radius == radius && halo.ratio == ratio) return halo;
    _halo?.dispose();
    return _halo = _Halo(tile, radius, ratio);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _halo?.dispose();
    super.dispose();
  }
}

/// The halo round a lifted app of one size: light bleeding round its edges,
/// a wide orange glow and a tight white-hot one, blurred once into images in
/// the colours of a full glow, which the painter fades with the heat.
/// Blurring it afresh on every frame cost a TV's GPU more than all the rest
/// of the dock together.
class _Halo {
  _Halo(this.tile, this.radius, this.ratio)
    : layers = [
        for (final (grow, blur, depth, opacity) in _layers)
          _blurred(tile, radius, ratio, grow, blur, molten(1, depth: depth, opacity: opacity)),
      ];

  /// Each layer: how far it reaches past the lifted tile, its blur, and its
  /// colour, as [molten]'s depth and opacity.
  static const _layers = [(12.0, 24.0, 0.45, 0.7), (3.0, 7.0, 0.08, 0.9)];

  final Size tile;
  final double radius, ratio;
  final List<ui.Image> layers;

  /// A rounded rectangle of [colour], [grow] larger than the lifted tile,
  /// blurred by [blur], centred in an image with room for the blur, at the
  /// screen's [ratio] of pixels.
  static ui.Image _blurred(Size tile, double radius, double ratio, double grow, double blur, Color colour) {
    final lifted = Size(tile.width * 1.12, tile.height * 1.12);
    final margin = grow + blur * 3;
    final size = Size(lifted.width + 2 * margin, lifted.height + 2 * margin);
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(ratio)
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: size.center(Offset.zero),
            width: lifted.width + 2 * grow,
            height: lifted.height + 2 * grow,
          ),
          Radius.circular(radius * 1.12 + grow),
        ),
        Paint()
          ..color = colour
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    final picture = recorder.endRecording();
    final image = picture.toImageSync((size.width * ratio).ceil(), (size.height * ratio).ceil());
    picture.dispose();
    return image;
  }

  void dispose() {
    for (final image in layers) {
      image.dispose();
    }
  }
}

/// Paints the dock's glow in the row of apps' own space, so it scrolls with
/// them. The glass lights up as if a lamp burned inside it, behind the app in
/// focus: the frosted glass glows around it, a fine filament of light runs
/// along the line and shows between the apps, light bleeds round the app's
/// edges, and the glass's top and bottom edges carry the light furthest.
/// Embers glow less, and without a filament.
class _MoltenPainter extends CustomPainter {
  _MoltenPainter(
    this.light, {
    required this.first,
    required this.step,
    required this.tile,
    required this.radius,
    required this.raise,
    required this.ratio,
  }) : super(repaint: light);

  final _Molten light;

  /// The first app's centre, and the distance from one app's to the next.
  final double first, step;
  final Size tile;
  final double radius;

  /// How far above the middle the tiles sit, making room for names.
  final double raise;

  /// The screen's pixels to a logical one, for the halo's images.
  final double ratio;

  static const _none = Color(0x00000000);

  @override
  void paint(Canvas canvas, Size size) {
    for (final (at, heat) in light.embers) {
      _spot(canvas, size, first + at * step, heat, 1, ember: true);
    }
    if (light.value case final glow?) {
      final stretch = 1 + 0.35 * (light.speed.abs() / 10).clamp(0.0, 1.0);
      _spot(canvas, size, first + glow.at * step, glow.heat, stretch);
    }
  }

  /// The light at [x]: an [ember] is only the glass still warm, with no
  /// filament and no halo round the app.
  void _spot(Canvas canvas, Size size, double x, double heat, double stretch, {bool ember = false}) {
    final centre = Offset(x, size.height / 2 - raise);
    final glass = size.height;
    // The frosted glass lit from within: brightest round the app, and
    // carried a long way along the line.
    _pool(
      canvas,
      centre,
      tile.width * 4.2 * stretch,
      glass,
      [
        molten(heat, depth: 0.3, opacity: 0.55 * heat),
        molten(heat, depth: 0.6, opacity: 0.3 * heat),
        molten(heat, depth: 0.9, opacity: 0.09 * heat),
        _none,
      ],
      const [0, 0.22, 0.55, 1],
    );
    if (!ember) {
      // Light bleeding round the app's edges: a wide orange glow, then a
      // tight one, white-hot, just past the lifted tile, drawn out a little
      // the way it flows. Each is one image, faded with the heat.
      final faded = Paint()
        ..color = Color.fromRGBO(0, 0, 0, heat.clamp(0.0, 1.0))
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.low;
      for (final image in light.halo(tile, radius, ratio).layers) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromCenter(
            center: centre,
            width: image.width / ratio + tile.width * 1.12 * (stretch - 1),
            height: image.height / ratio,
          ),
          faded,
        );
      }
    }
    if (!ember) {
      // A fine filament of light through the glass, level with the apps'
      // middles: it shows in the gaps between them, fading along the line.
      for (final (high, depth, opacity) in [(7.0, 0.5, 0.4), (1.6, 0.05, 0.8)]) {
        _pool(
          canvas,
          centre,
          tile.width * 4.5 * stretch,
          high,
          [
            molten(heat, depth: depth, opacity: opacity * heat),
            molten(heat, depth: depth + 0.4, opacity: 0.3 * opacity * heat),
            _none,
          ],
          const [0, 0.35, 1],
        );
      }
    }
    // The glass's edges carry the light furthest, the top more than the
    // bottom: hottest right over the app, then a long tail along the line.
    for (final (y, strength) in [(1.0, 1.0), (glass - 1, 0.75)]) {
      final line = Rect.fromCenter(center: Offset(x, y), width: tile.width * 10, height: 2);
      final tail = molten(heat, depth: 0.75, opacity: 0.3 * heat * strength);
      canvas.drawRect(
        line,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = LinearGradient(
            colors: [
              _none,
              tail,
              molten(heat, depth: 0.12, opacity: heat * strength),
              tail,
              _none,
            ],
            stops: const [0, 0.36, 0.5, 0.64, 1],
          ).createShader(line),
      );
    }
  }

  /// A soft oval of light, [across] wide and [high] tall from its centre,
  /// [colours] running from the centre outward, added to the glass. Only
  /// gradients and the rounded rectangles' own fast blur draw the glow, as a
  /// TV under a moving wallpaper redraws it every frame.
  static void _pool(
    Canvas canvas,
    Offset centre,
    double across,
    double high,
    List<Color> colours, [
    List<double>? stops,
  ]) {
    canvas
      ..save()
      ..translate(centre.dx, centre.dy)
      ..scale(across / high, 1)
      ..drawCircle(
        Offset.zero,
        high,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: colours,
            stops: stops,
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: high)),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_MoltenPainter old) =>
      old.light != light ||
      old.first != first ||
      old.step != step ||
      old.tile != tile ||
      old.radius != radius ||
      old.raise != raise ||
      old.ratio != ratio;
}
