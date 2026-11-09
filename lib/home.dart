import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'glow.dart';
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

  /// 1: the screensaver, with everything but the wallpaper out of sight.
  late final _saver = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
    reverseDuration: Look.medium,
  );
  late final _saving = CurvedAnimation(parent: _saver, curve: Curves.easeInOutCubic);
  late final _present = ReverseAnimation(_saving);
  final _dock = FocusScopeNode(debugLabel: 'dock');
  final _grid = FocusScopeNode(debugLabel: 'grid');
  final _gridScroll = ScrollController();
  final _dockScroll = ScrollController();
  final _bar = FocusScopeNode(debugLabel: 'bar');

  /// The top bar is on screen: while it has focus.
  final _barShown = ValueNotifier(false);

  /// The dock app being moved, if any.
  String? _moving;

  /// The glow in the dock's glass, and the dock app it is under, by package.
  late final _molten = _Molten(this);
  String? _glowing;
  StreamSubscription<Object?>? _homeKey, _opens;

  /// Where focus last was on this screen, and in the dock which app, by its place.
  FocusScopeNode? _lastScope;
  int _dockAt = 0;

  /// Waiting to see whether focus has really gone nowhere.
  Timer? _lost;

  @override
  void initState() {
    super.initState();
    // The glow's shader: until it loads, the dock simply has no glow.
    GlowShader.load().then((_) {
      if (mounted) setState(() {});
    });
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
    s.saver.addListener(_onSaver);
    s.apps.addListener(_checkFocus);
    FocusManager.instance.addListener(_checkFocus);
  }

  @override
  void dispose() {
    _homeKey?.cancel();
    _opens?.cancel();
    s.saver.removeListener(_onSaver);
    s.apps.removeListener(_checkFocus);
    FocusManager.instance.removeListener(_checkFocus);
    _lost?.cancel();
    _eased.dispose();
    _page.dispose();
    _saving.dispose();
    _saver.dispose();
    _dock.dispose();
    _grid.dispose();
    _gridScroll.dispose();
    _dockScroll.dispose();
    _bar.dispose();
    _barShown.dispose();
    _molten.dispose();
    super.dispose();
  }

  /// Everything closes and the dock waits, out of sight, for the button that
  /// brings it back.
  void _onSaver() {
    if (s.saver.value) {
      _goHome(closeMenus: true);
      _saver.forward();
    } else {
      _saver.reverse();
    }
  }

  /// An item is always in focus, or the remote does nothing. When a focused
  /// item goes, Flutter falls back on whichever was focused before it, and
  /// with none on the scope around it or the screen as a whole, where nothing
  /// shows as selected and keys may reach no item. Focus also passes through
  /// such places on its way between items, as a menu opens: focus still there
  /// a moment later is lost.
  void _checkFocus() {
    if (!_noItem) return;
    _lost ??= Timer(const Duration(milliseconds: 100), () {
      _lost = null;
      if (mounted && _noItem) _refocus();
    });
  }

  /// A scope has focus, not an item in it. A level of settings with no rows
  /// takes focus itself, so that Left still works there.
  bool get _noItem => switch (FocusManager.instance.primaryFocus) {
    final FocusScopeNode scope => _onTop || scope.traversalDescendants.isNotEmpty,
    _ => false,
  };

  /// Focuses the nearest item: on the home screen in the place focus last was,
  /// else on the screen over it the item focused last there, else its first.
  void _refocus() {
    if (!_onTop) {
      final route = Navigator.of(context).focusNode.enclosingScope?.focusedChild;
      if (route is! FocusScopeNode) return;
      FocusNode? item = route;
      while (item is FocusScopeNode) {
        item = item.focusedChild;
      }
      (item ?? route.traversalDescendants.where((node) => node is! FocusScopeNode).firstOrNull)?.requestFocus();
      return;
    }
    // The dock's first app takes focus as soon as the apps are known.
    if (!s.apps.loaded) return;
    if (_moving != null) setState(() => _moving = null);
    final apps = s.apps.dock;
    final last = _lastScope;
    final item = last == null || last == _dock ? null : last.focusedChild ?? _topLeft(last);
    if (item != null) {
      item.requestFocus();
      if (item.context case final context?) reveal(context);
    } else if (apps.isNotEmpty) {
      _focusTile(_dock, apps[_dockAt.clamp(0, apps.length - 1)].package);
    } else {
      _goHome();
    }
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
    final allGone = s.apps.loaded && s.apps.dock.isEmpty && _grid.traversalDescendants.isEmpty;
    // With nothing in the dock or below it, the top bar's gear is always there.
    _enter(allGone ? _bar : (s.apps.dock.isEmpty ? _grid : _dock));
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
              IgnorePointer(
                child: FadeTransition(
                  opacity: _present,
                  child: const DecoratedBox(
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
              ),
              // Dims the wallpaper behind the app grid.
              IgnorePointer(
                child: FadeTransition(
                  opacity: eased,
                  child: FadeTransition(
                    opacity: _present,
                    child: const ColoredBox(color: Color(0x73000000)),
                  ),
                ),
              ),
              // Under the settings panel only the wallpaper shows.
              UnderSettings(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ListenableBuilder(
                      listenable: Listenable.merge([s.apps, s.config, s.plex, s.appRows]),
                      builder: (context, _) => Stack(
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: g.gridTop,
                            bottom: 0,
                            child: FadeTransition(
                              opacity: _present,
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
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: g.dockIdle - _bleedRoom,
                            height: g.dockHeight + 2 * _bleedRoom,
                            child: AnimatedBuilder(
                              animation: Listenable.merge([eased, _saving]),
                              child: RepaintBoundary(child: _dockBar(g)),
                              // Off the bottom for the screensaver.
                              builder: (context, dock) {
                                final moved = Offset(
                                  0,
                                  eased.value * (g.dockTop - g.dockIdle) +
                                      _saving.value * (g.height - g.dockIdle + _bleedRoom),
                                );
                                return Transform.translate(
                                  offset: moved,
                                  child: Offstage(
                                    offstage: _saving.value == 1,
                                    child: Stack(
                                      children: [
                                        // A still picture behind, blurred, under the lamp's light on it and the glass.
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          top: _bleedRoom,
                                          height: g.dockHeight,
                                          child: WallpaperBlur(moving: moved),
                                        ),
                                        Positioned.fill(
                                          child: RepaintBoundary(
                                            child: _bleed(g, (1 - eased.value) * (1 - _saving.value)),
                                          ),
                                        ),
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          top: _bleedRoom,
                                          height: g.dockHeight,
                                          child: dock!,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: g.dockIdle - 48,
                            child: Center(
                              child: FadeTransition(
                                opacity: _present,
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
                          ),
                        ],
                      ),
                    ),
                    // A soft shade behind the time and date only, so they hold on bright film.
                    Positioned(
                      right: 0,
                      top: 0,
                      width: 480,
                      height: 240,
                      child: IgnorePointer(
                        child: ListenableBuilder(
                          listenable: _clockChanges,
                          builder: (context, shade) =>
                              AnimatedOpacity(opacity: _clockShown ? 1 : 0, duration: Look.medium, child: shade),
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(0.22, -0.1),
                                colors: [Color(0x66000000), Color(0x00000000)],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // The icons' glyphs line up with the dock's first app.
                    Positioned(
                      left: g.pad - (_chipGap + _chip - _glyph) / 2,
                      right: g.pad,
                      top: g.pad - 8,
                      child: _topBar(),
                    ),
                  ],
                ),
              ),
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
    if (glowing >= 0) {
      _dockAt = glowing;
      _molten.focus(glowing);
    }
    final names = c.dockNames ? _Geometry.labelHeight : 0.0;
    final (first, step) = _centres(g, apps.length, c.dockAlign);
    // With the glow off, the apps take focus as they do elsewhere.
    final strength = GlowLook.strength(c.glowLevel);
    final look = strength == null ? null : GlowLook.look;
    _molten.step = step;
    if (strength != null) _molten.set(GlowColour.of(c.glowColour), strength);
    return FocusScope(
      node: _dock,
      onKeyEvent: _onDockKey,
      onFocusChange: (focused) {
        if (focused) {
          _lastScope = _dock;
          _page.reverse();
        } else {
          _glowing = null;
          _molten.focus(null);
        }
      },
      child: Glass(
        tint: Tints.glass(c.tintColour, c.tintLevel),
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
                    controller: _dockScroll,
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(horizontal: g.pad - g.gap / 2),
                    // At least the screen's width, so apps that fit can spread across it.
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: g.width - 2 * g.pad + g.gap),
                      // The glow, behind the apps and moving along with them.
                      child: CustomPaint(
                        painter: look == null
                            ? null
                            : _MoltenPainter(
                                _molten,
                                first: first,
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
                                    glow: look == null ? null : _molten,
                                    index: i,
                                    onDown: look == null ? null : _molten.press,
                                    onFocusChange: (focused) {
                                      if (!focused) return;
                                      _glowing = apps[i].package;
                                      _dockAt = i;
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

  /// Room above and below the dock for the light its lamp throws on the wallpaper.
  static const _bleedRoom = 120.0;

  /// The light the dock's lamp throws on the wallpaper round it, [fade]d as the dock slides away.
  Widget _bleed(_Geometry g, double fade) {
    if (s.config.glowLevel <= 0) return const SizedBox.shrink();
    final apps = s.apps.dock;
    final names = s.config.dockNames ? _Geometry.labelHeight : 0.0;
    final (first, _) = _centres(g, apps.length, s.config.dockAlign);
    return CustomPaint(
      painter: _BleedPainter(
        _molten,
        _dockScroll,
        left: g.pad - g.gap / 2,
        first: first,
        tile: Size(g.tileWidth, g.tileHeight),
        radius: g.radius,
        raise: names / 2,
        room: _bleedRoom,
        fade: fade,
        ratio: MediaQuery.devicePixelRatioOf(context),
      ),
    );
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
        if (!focused) return;
        _lastScope = _grid;
        _page.forward();
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

  /// A top icon's size, the gap between them, and the size of the glyph in one.
  static const _chip = 40.0, _chipGap = 8.0, _glyph = 26.0;

  /// The clock shows with the top bar, and on its own while a face is tried in settings.
  bool get _clockShown => _barShown.value || s.clockTrial.value != null;
  late final _clockChanges = Listenable.merge([_barShown, s.clockTrial]);

  /// Fades and slides the top bar's [child] in and out.
  Widget _appearing(bool shown, Widget? child) => AnimatedOpacity(
    opacity: shown ? 1 : 0,
    duration: Look.fast,
    child: AnimatedSlide(
      offset: shown ? Offset.zero : const Offset(0, -0.3),
      duration: Look.medium,
      curve: Look.ease,
      child: child,
    ),
  );

  Widget _topBar() => FocusScope(
    node: _bar,
    onKeyEvent: _onBarKey,
    onFocusChange: (focused) {
      _barShown.value = focused;
      if (focused) _lastScope = _bar;
    },
    child: ListenableBuilder(
      listenable: Listenable.merge([s.config, s.status, s.updates]),
      builder: (context, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _barShown,
            builder: (context, shown, icons) => _appearing(shown, icons),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final id in s.config.topIcons) ?_topIcon(id)],
            ),
          ),
          const Spacer(),
          ListenableBuilder(
            listenable: _clockChanges,
            builder: (context, _) => _appearing(
              _clockShown,
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Opacity(
                    opacity: s.config.clockOpacity,
                    child: Clock(h24: s.config.clock24, face: s.clockTrial.value ?? s.config.clockFont),
                  ),
                  ValueListenableBuilder<String?>(
                    valueListenable: s.caption,
                    builder: (context, caption, _) => caption == null || caption.isEmpty || !s.config.showCaption
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(caption, style: Look.caption),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget? _topIcon(String id) {
    final hidden = s.config.topHidden.contains(id);
    final glow = s.config.glowLevel > 0 ? GlowColour.of(s.config.glowColour) : null;
    switch (id) {
      case 'settings':
        // Always there so Up can reach it: a hidden gear shows only while
        // focused, so settings can never be locked away.
        return TopIcon(
          key: ValueKey(id),
          icon: Glyphs.gear,
          collapsed: hidden,
          glow: glow,
          // An update waits in settings, under About.
          badge: s.updates.waiting,
          onPressed: () => showSettings(context),
        );
      case 'network' when !hidden:
        return TopIcon(
          key: ValueKey(id),
          icon: s.status.networkIcon,
          glow: glow,
          onPressed: () => Native.openSettings('android.settings.WIFI_SETTINGS'),
        );
      case 'vpn' when !hidden:
        final app = s.status.vpnApp;
        if (app == null) return null;
        return TopIcon(
          key: ValueKey(id),
          icon: s.status.vpn ? Glyphs.vpnOn : Glyphs.vpnOff,
          glow: glow,
          onPressed: () async {
            if (!await Native.launch(app.package)) s.notice.show("Couldn't open ${app.name}");
          },
        );
    }
    return null;
  }
}

/// A top-bar icon, straight on the wallpaper. In focus it becomes a small dark
/// tile in front of the dock's glow, as a dock app does.
class TopIcon extends StatelessWidget {
  const TopIcon({
    super.key,
    required this.icon,
    required this.onPressed,
    this.collapsed = false,
    this.badge = false,
    this.glow,
  });

  final IconData icon;
  final VoidCallback onPressed;

  /// Takes no space until focused.
  final bool collapsed;

  /// A dot on its corner: something waits behind it.
  final bool badge;

  /// The glow's colour behind it in focus; null with the dock's glow off.
  final GlowColour? glow;

  static const _chip = _HomeScreenState._chip;

  /// How much a tile in focus is enlarged.
  static const _lift = 1.08;

  /// What the tile's edge catches of the glow behind it, by its colour.
  static final _rims = <GlowColour, Color>{};

  static Color _rim(GlowColour colour) => _rims.putIfAbsent(colour, () {
    final lamp = _chip / 2 * GlowLook.lampScale;
    final light = GlowLook.rim * GlowHalo.look.light(_chip / 2 * _lift, 0, lamp, lamp, lamp);
    final (r, g, b) = colour.light(1);
    int channel(double c) => (255 * GlowLook.tone(light * c)).round();
    return Color.fromARGB(255, channel(r), channel(g), channel(b));
  });

  @override
  Widget build(BuildContext context) => Pressable(
    onPressed: onPressed,
    builder: (context, focused) {
      final glow = this.glow;
      final tile = AnimatedScale(
        scale: focused ? _lift : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.fast,
          curve: Look.ease,
          width: _chip,
          height: _chip,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: focused ? const Color(0xF21C1C1E) : const Color(0x001C1C1E),
            border: Border.all(
              color: !focused
                  ? const Color(0x00FFFFFF)
                  : glow != null
                  ? _rim(glow)
                  : const Color(0x38FFFFFF),
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(
                icon,
                size: _HomeScreenState._glyph,
                color: Look.white.withValues(alpha: focused ? 1 : 0.92),
                shadows: focused ? null : Look.shadow,
              ),
              if (badge) const Positioned(right: 5, top: 5, child: Badge()),
            ],
          ),
        ),
      );
      final item = Padding(
        padding: const EdgeInsets.symmetric(horizontal: _HomeScreenState._chipGap / 2),
        child: glow == null
            ? tile
            // On like a bulb as focus reaches it, out fast as focus leaves.
            : TweenAnimationBuilder<double>(
                tween: Tween(end: focused ? 1 : 0),
                duration: focused ? const Duration(milliseconds: 80) : const Duration(milliseconds: 200),
                child: tile,
                builder: (context, heat, tile) => CustomPaint(
                  painter: heat == 0
                      ? null
                      : _HaloPainter(
                          heat,
                          glow,
                          radius: _chip / 2 * GlowLook.lampScale,
                          ratio: MediaQuery.devicePixelRatioOf(context),
                        ),
                  child: tile,
                ),
              ),
      );
      if (!collapsed) return item;
      return ClipRect(
        child: Align(alignment: Alignment.centerLeft, widthFactor: focused ? 1 : 0, child: item),
      );
    },
  );
}

/// Places the glow's one image, added to the wallpaper, at [heat], in [colour].
class _HaloPainter extends CustomPainter {
  _HaloPainter(this.heat, this.colour, {required this.radius, required this.ratio});

  final double heat, radius, ratio;
  final GlowColour colour;

  @override
  void paint(Canvas canvas, Size size) {
    final image = GlowHalo.image(radius, ratio, colour);
    if (image == null) return;
    final (r, g, b) = colour.fade(heat);
    if (r <= 0) return;
    final side = 2 * (radius + GlowHalo.reach);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, side * ratio, side * ratio),
      Rect.fromCenter(center: size.center(Offset.zero), width: side, height: side),
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.low
        ..colorFilter = ColorFilter.mode(Color.from(alpha: r, red: 1, green: g / r, blue: b / r), BlendMode.modulate),
    );
  }

  @override
  bool shouldRepaint(_HaloPainter old) =>
      old.heat != heat || old.colour != colour || old.radius != radius || old.ratio != ratio;
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

/// The dock's light: a lamp in the glass behind the app in focus. It comes
/// on behind an app as focus reaches it, as a bulb does, up through red in
/// a blink; the one behind the app focus left goes out fast where it was,
/// an ember, as the lamp does when focus leaves the dock. It ticks only
/// while something changes.
class _Molten extends ChangeNotifier implements ValueListenable<Glow?> {
  _Molten(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  Duration? _last;
  double _at = 0, _heat = 0, _hot = 0;

  /// How fast a lamp comes on, and goes out (each an exponential rate, a second).
  static const _on = 25.0, _out = 8.0;

  /// Lamps going out where focus was, as (place, heat).
  final embers = <(double, double)>[];

  @override
  Glow? get value => _heat < 0.005 ? null : Glow(_at, _heat, step, look, _colour, _strength);

  /// The look it is drawn in.
  GlowLook get look => GlowLook.look;

  /// Its colour and strength (the glow settings), set as the dock lays out.
  GlowColour get colour => _colour;
  GlowColour _colour = GlowColour.of(GlowColour.orange);
  double get strength => _strength;
  double _strength = 1;

  void set(GlowColour colour, double strength) {
    if (colour == _colour && strength == _strength) return;
    _colour = colour;
    _strength = strength;
    // A tick shows it, on the tiles' edges too.
    _start();
  }

  /// OK is down on the app in focus: the glow flares while it is.
  void press(bool down) {
    if (_hot == 0) return;
    _hot = down ? 1.35 : 1;
    _start();
  }

  /// Focus is on the dock app at [index], or has left the dock (null).
  void focus(int? index) {
    final hot = index == null ? 0.0 : 1.0;
    final at = index?.toDouble() ?? _at;
    if (at == _at && hot == _hot) return;
    if (at != _at) {
      // The lamp behind the app left goes out there; the new app's comes on from dark.
      if (_heat > 0.02) {
        embers.add((_at, _heat));
        if (embers.length > 3) embers.removeAt(0);
      }
      _at = at;
      _heat = 0;
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
    _heat += (_hot - _heat) * (1 - math.exp(-dt * (_hot > _heat ? _on : _out)));
    for (var i = embers.length - 1; i >= 0; i--) {
      final (at, heat) = embers[i];
      final cooler = heat * math.exp(-dt * _out);
      if (cooler < 0.01) {
        embers.removeAt(i);
      } else {
        embers[i] = (at, cooler);
      }
    }
    if ((_hot - _heat).abs() < 0.002 && embers.isEmpty) {
      _heat = _hot;
      _ticker.stop();
    }
    notifyListeners();
  }

  /// Its light in the glass and on the wallpaper, drawn once for the dock
  /// as it is (see GlowSprite), and again only when that changes.
  GlowSprite? _glass, _wall;

  GlowSprite? glass(GlowKey key) => _glass = _sprite(_glass, key);
  GlowSprite? wall(GlowKey key) => _wall = _sprite(_wall, key);

  static GlowSprite? _sprite(GlowSprite? sprite, GlowKey key) {
    if (sprite != null && sprite.key == key) return sprite;
    sprite?.dispose();
    return GlowSprite.draw(key);
  }

  /// The distance from one app's centre to the next, set as the dock lays out.
  double step = 0;

  /// The lamps to draw, the one in focus first, along a row whose first app
  /// is centred at [first]: each its centre and heat, and whether it is going
  /// out.
  List<Spot> spots(double first, double offset) => [
    if (value case final glow?) (x: offset + first + glow.at * step, heat: glow.heat, ember: false),
    for (final (at, heat) in embers) (x: offset + first + at * step, heat: heat, ember: true),
  ];

  @override
  void dispose() {
    _ticker.dispose();
    _glass?.dispose();
    _wall?.dispose();
    super.dispose();
  }
}

/// Paints the dock's glow in the row of apps' own space, so it scrolls with
/// them: a lamp behind the frosted glass under the app in focus, and its
/// embers (see glow.dart). The band fills the painter's height.
class _MoltenPainter extends CustomPainter {
  _MoltenPainter(
    this.light, {
    required this.first,
    required this.tile,
    required this.radius,
    required this.raise,
    required this.ratio,
  }) : super(repaint: light);

  final _Molten light;

  /// The first app's centre, the apps' tile size and corner radius.
  final double first;
  final Size tile;
  final double radius;

  /// How far above the middle the tiles sit, making room for names.
  final double raise;

  /// The screen's pixels to a dp, for the glow's images.
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    final spots = light.spots(first, 0);
    if (spots.isEmpty) return;
    final sprite = light.glass((
      look: light.look,
      colour: light.colour,
      strength: light.strength,
      hw: tile.width * GlowLook.lampScale / 2,
      hh: tile.height * GlowLook.lampScale / 2,
      r: radius * GlowLook.lampScale,
      height: size.height,
      y: size.height / 2 - raise,
      top: 0,
      bottom: size.height,
      wallpaper: false,
      ratio: ratio,
    ));
    for (final spot in spots) {
      sprite?.place(canvas, spot.x, 0, heat: spot.heat, ember: spot.ember);
    }
  }

  @override
  bool shouldRepaint(_MoltenPainter old) =>
      old.light != light ||
      old.first != first ||
      old.tile != tile ||
      old.radius != radius ||
      old.raise != raise ||
      old.ratio != ratio;
}

/// Paints the light the dock's lamp throws on the wallpaper above and below
/// it, under the dock (whose glass softens what of it lies behind), following
/// the dock's apps as they scroll. [room] is the room above and below the
/// band; [fade] dims it as the dock slides away.
class _BleedPainter extends CustomPainter {
  _BleedPainter(
    this.light,
    this.scroll, {
    required this.left,
    required this.first,
    required this.tile,
    required this.radius,
    required this.raise,
    required this.room,
    required this.fade,
    required this.ratio,
  }) : super(repaint: Listenable.merge([light, scroll]));

  final _Molten light;
  final ScrollController scroll;

  /// Where the row of apps starts, and its first app's centre in it.
  final double left, first;
  final Size tile;
  final double radius, raise, room, fade;

  /// The screen's pixels to a dp; the wallpaper's light, being soft, is
  /// drawn at half of them (fewer blur its sharp edge at the dock's).
  final double ratio;

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    final spots = light.spots(first, left - (scroll.hasClients ? scroll.offset : 0));
    if (spots.isEmpty) return;
    final sprite = light.wall((
      look: light.look,
      colour: light.colour,
      strength: light.strength,
      hw: tile.width * GlowLook.lampScale / 2,
      hh: tile.height * GlowLook.lampScale / 2,
      r: radius * GlowLook.lampScale,
      height: size.height,
      y: size.height / 2 - raise,
      top: room,
      bottom: size.height - room,
      wallpaper: true,
      ratio: ratio / 2,
    ));
    for (final spot in spots) {
      sprite?.place(canvas, spot.x, 0, heat: spot.heat, ember: spot.ember, opacity: fade);
    }
  }

  @override
  bool shouldRepaint(_BleedPainter old) =>
      old.light != light ||
      old.scroll != scroll ||
      old.left != left ||
      old.first != first ||
      old.tile != tile ||
      old.radius != radius ||
      old.raise != raise ||
      old.room != room ||
      old.fade != fade ||
      old.ratio != ratio;
}

/// The dock as settings will leave it, in a window of its own beside them: a
/// stretch of its glass at the screen's own scale, an app lit in the middle
/// and its neighbours either side, drawn by the dock's own parts. A choice
/// being tried in settings (Services.dockTrial) shows in place of the
/// setting, so each one can be seen before it is chosen.
class DockPreview extends StatefulWidget {
  const DockPreview({super.key});

  @override
  State<DockPreview> createState() => _DockPreviewState();
}

class _DockPreviewState extends State<DockPreview> with SingleTickerProviderStateMixin {
  late final Services s = Services.of(context);
  late final _molten = _Molten(this);

  /// The bleed's painter follows a scroll; this one never scrolls.
  final _still = ScrollController();

  /// Apps shown, and the lit one among them, in the middle.
  static const _count = 5, _lit = 2;

  /// Room above and below the glass, for the light its lamp throws there.
  static const _room = 44.0;

  @override
  void initState() {
    super.initState();
    _molten.focus(_lit);
  }

  @override
  void dispose() {
    _molten.dispose();
    _still.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([s.config, s.dockTrial, s.apps]),
    builder: (context, _) {
      final c = s.config;
      final tried = s.dockTrial.value;
      T pick<T>(String key, T setting) => switch (tried[key]) {
        final T value => value,
        _ => setting,
      };
      final names = pick('dockNames', c.dockNames);
      final g = _Geometry(
        MediaQuery.sizeOf(context),
        dockSize: pick('dockSize', c.dockSize),
        square: pick('tileShape', c.tileShape) == 'square',
        spacing: pick('dockSpacing', c.dockSpacing),
        corners: pick('tileCorners', c.tileCorners),
        room: pick('dockRoom', c.dockRoom),
        names: names,
      );
      final strength = GlowLook.strength(pick('glowLevel', c.glowLevel));
      final cell = g.tileWidth + g.gap;
      _molten.step = cell;
      if (strength != null) _molten.set(GlowColour.of(pick('glowColour', c.glowColour)), strength);
      final label = names ? _Geometry.labelHeight : 0.0;
      final tile = Size(g.tileWidth, g.tileHeight);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final apps = [...s.apps.dock, ...s.apps.all.where((app) => !s.apps.inDock(app.package))].take(_count).toList();
      return LayoutBuilder(
        builder: (context, box) {
          // The row of apps, placed so the lit one sits in the middle.
          final left = box.maxWidth / 2 - (_lit + 0.5) * cell;
          return ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: SizedBox(
              height: g.dockHeight + 2 * _room,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: gradients[c.gradient.clamp(0, gradients.length - 1)].$2,
                        ),
                      ),
                    ),
                  ),
                  if (strength != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BleedPainter(
                          _molten,
                          _still,
                          left: left,
                          first: cell / 2,
                          tile: tile,
                          radius: g.radius,
                          raise: label / 2,
                          room: _room,
                          fade: 1,
                          ratio: ratio,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: _room,
                    height: g.dockHeight,
                    child: Glass(
                      tint: Tints.glass(pick('tintColour', c.tintColour), pick('tintLevel', c.tintLevel)),
                      child: CustomPaint(
                        painter: _BandLight(
                          line: pick('lineWidth', c.lineWidth),
                          alpha: pick('lineAlpha', c.lineAlpha),
                        ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: left,
                              top: 0,
                              bottom: 0,
                              width: _count * cell,
                              child: CustomPaint(
                                painter: strength == null
                                    ? null
                                    : _MoltenPainter(
                                        _molten,
                                        first: cell / 2,
                                        tile: tile,
                                        radius: g.radius,
                                        raise: label / 2,
                                        ratio: ratio,
                                      ),
                                child: Row(
                                  children: [
                                    for (var i = 0; i < apps.length; i++)
                                      Padding(
                                        padding: EdgeInsets.symmetric(horizontal: g.gap / 2),
                                        child: SizedBox(
                                          width: g.tileWidth,
                                          height: g.tileHeight + label,
                                          child: AppTile(
                                            app: apps[i],
                                            square: g.square,
                                            radius: g.radius,
                                            label: names,
                                            lit: i == _lit,
                                            glow: strength == null ? null : _molten,
                                            index: i,
                                            onLaunch: () {},
                                            onMenu: () {},
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // A rim like the panels', over it all.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
