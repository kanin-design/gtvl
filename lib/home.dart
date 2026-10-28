import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'menu.dart';
import 'native.dart';
import 'services.dart';
import 'settings.dart';
import 'tile.dart';
import 'ui.dart';
import 'wallpaper.dart';

/// Sizes derived from the screen, so the layout fits any TV.
class _Geometry {
  _Geometry(Size size) : width = size.width, height = size.height, pad = (size.width * 0.04).roundToDouble() {
    gap = (width * 0.014).roundToDouble();
    tileWidth = (width - 2 * pad - (columns - 1) * gap) / columns;
    tileHeight = tileWidth * 9 / 16;
    // Room above and below a tile for its focus lift and shadow.
    dockHeight = tileHeight * 1.36;
    dockIdle = height - dockHeight - height * 0.07;
    dockTop = height * 0.06;
    gridTop = dockTop + dockHeight + height * 0.02;
  }

  static const columns = 6;
  static const labelHeight = 26.0;
  final double width, height, pad;
  late final double gap, tileWidth, tileHeight, dockHeight, dockIdle, dockTop, gridTop;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final Services s = Services.of(context);

  /// 0: home, with the dock near the bottom. 1: all apps, the dock at the top.
  late final _page = AnimationController(vsync: this, duration: Look.medium);
  late final _eased = CurvedAnimation(parent: _page, curve: Curves.easeInOutCubic);
  final _dock = FocusScopeNode(debugLabel: 'dock');
  final _grid = FocusScopeNode(debugLabel: 'grid');
  final _bar = FocusScopeNode(debugLabel: 'bar');

  /// The top bar is on screen: revealed by Up from the dock, or focused.
  final _barShown = ValueNotifier(false);
  Timer? _conceal;

  /// The dock app being moved, if any.
  String? _moving;
  StreamSubscription<Object?>? _homeKey;

  @override
  void initState() {
    super.initState();
    // Home pressed while already home: close menus, back to the dock.
    _homeKey = Native.events.where((event) => event['type'] == 'home').listen((_) => _goHome(closeMenus: true));
  }

  @override
  void dispose() {
    _homeKey?.cancel();
    _conceal?.cancel();
    _eased.dispose();
    _page.dispose();
    _dock.dispose();
    _grid.dispose();
    _bar.dispose();
    _barShown.dispose();
    super.dispose();
  }

  /// Focuses the item last focused in [scope], or its first one.
  void _enter(FocusScopeNode scope) {
    final target = scope.focusedChild ?? (scope.traversalDescendants.isEmpty ? null : scope.traversalDescendants.first);
    target?.requestFocus();
  }

  void _goHome({bool closeMenus = false}) {
    if (closeMenus) Navigator.of(context).popUntil((route) => route.isFirst);
    if (_moving != null) setState(() => _moving = null);
    _hideBar();
    _enter(s.apps.dock.isEmpty ? _grid : _dock);
  }

  void _revealBar() {
    _barShown.value = true;
    _conceal?.cancel();
    _conceal = Timer(const Duration(seconds: 5), _hideBar);
  }

  void _hideBar() {
    _conceal?.cancel();
    if (!_bar.hasFocus) _barShown.value = false;
  }

  static bool _isPress(KeyEvent event) => event is KeyDownEvent || event is KeyRepeatEvent;

  KeyEventResult _onDockKey(FocusNode node, KeyEvent event) {
    if (_moving != null || !_isPress(event)) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        // The first Up shows the top bar; the next one moves into it.
        if (event is KeyDownEvent) {
          if (_barShown.value) {
            _enter(_bar);
          } else {
            _revealBar();
          }
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _hideBar();
        if (event is KeyDownEvent) _enter(_grid);
        return KeyEventResult.handled;
      default:
        _hideBar();
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    if (!_isPress(event) || event.logicalKey != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    // Up from the top row goes back to the dock.
    final moved = FocusManager.instance.primaryFocus?.focusInDirection(TraversalDirection.up) ?? false;
    if (!moved && event is KeyDownEvent) _enter(_dock);
    return KeyEventResult.handled;
  }

  KeyEventResult _onBarKey(FocusNode node, KeyEvent event) {
    if (!_isPress(event)) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) _enter(_dock);
      return KeyEventResult.handled;
    }
    return event.logicalKey == LogicalKeyboardKey.arrowUp ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// Keys for the dock app being moved: Left and Right move it, OK or Back puts it down.
  KeyEventResult _onMoveKey(KeyEvent event) {
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

  void _menu(AppInfo app) => showAppMenu(
    context,
    app,
    onMove: s.apps.inDock(app.package) ? () => setState(() => _moving = app.package) : null,
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _onBack();
    },
    child: LayoutBuilder(
      builder: (context, box) {
        final g = _Geometry(box.biggest);
        final eased = _eased;
        return Stack(
          fit: StackFit.expand,
          children: [
            const Wallpaper(),
            // Dims the wallpaper behind the app grid.
            IgnorePointer(
              child: FadeTransition(
                opacity: eased,
                child: const ColoredBox(color: Color(0x73000000)),
              ),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([s.apps, s.config]),
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
                ],
              ),
            ),
            Positioned(left: g.pad - 10, right: g.pad, top: g.height * 0.045, child: _topBar()),
          ],
        );
      },
    ),
  );

  Widget _dockBar(_Geometry g) {
    final apps = s.apps.dock;
    return FocusScope(
      node: _dock,
      onKeyEvent: _onDockKey,
      onFocusChange: (focused) {
        if (focused) _page.reverse();
      },
      child: Glass(
        border: const Border.symmetric(horizontal: BorderSide(color: Look.hairline)),
        child: apps.isEmpty
            ? Center(child: Text(s.apps.loaded ? 'Hold OK on an app to add it here' : '', style: Look.value))
            : FocusTraversalGroup(
                policy: smoothTraversal,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    padding: EdgeInsets.symmetric(horizontal: g.pad - g.gap / 2),
                    child: Row(
                      children: [
                        for (var i = 0; i < apps.length; i++)
                          Padding(
                            key: ValueKey(apps[i].package),
                            padding: EdgeInsets.symmetric(horizontal: g.gap / 2),
                            child: SizedBox(
                              width: g.tileWidth,
                              height: g.tileHeight,
                              child: AppTile(
                                app: apps[i],
                                autofocus: i == 0,
                                moving: _moving == apps[i].package,
                                onKey: _moving == apps[i].package ? _onMoveKey : null,
                                onLaunch: () => Native.launch(apps[i].package),
                                onMenu: () => _menu(apps[i]),
                              ),
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

  Widget _gridView(_Geometry g) {
    final apps = s.apps.others;
    return FocusScope(
      node: _grid,
      onKeyEvent: _onGridKey,
      onFocusChange: (focused) {
        if (focused) _page.forward();
      },
      child: FocusTraversalGroup(
        policy: smoothTraversal,
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(g.pad, 18, g.pad, 60),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: _Geometry.columns,
            crossAxisSpacing: g.gap,
            mainAxisSpacing: g.gap * 0.6,
            childAspectRatio: g.tileWidth / (g.tileHeight + _Geometry.labelHeight),
          ),
          itemCount: apps.length,
          itemBuilder: (context, i) => AppTile(
            key: ValueKey(apps[i].package),
            app: apps[i],
            label: true,
            autofocus: i == 0 && s.apps.dock.isEmpty,
            onLaunch: () => Native.launch(apps[i].package),
            onMenu: () => _menu(apps[i]),
          ),
        ),
      ),
    );
  }

  Widget _topBar() => FocusScope(
    node: _bar,
    onKeyEvent: _onBarKey,
    onFocusChange: (focused) {
      if (focused) {
        _conceal?.cancel();
        _barShown.value = true;
      } else {
        _barShown.value = false;
      }
    },
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
        listenable: Listenable.merge([s.config, s.status]),
        builder: (context, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final id in s.config.topIcons) ?_topIcon(id),
            const Spacer(),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Clock(h24: s.config.clock24),
                ValueListenableBuilder<String?>(
                  valueListenable: s.caption,
                  builder: (context, caption, _) => caption == null || caption.isEmpty
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
        return TopIcon(icon: Icons.settings_outlined, collapsed: hidden, onPressed: () => showSettings(context));
      case 'network' when !hidden:
        return TopIcon(
          icon: s.status.networkIcon,
          onPressed: () => Native.openSettings('android.settings.WIFI_SETTINGS'),
        );
      case 'vpn' when !hidden:
        final app = s.status.vpnApp;
        if (app == null) return null;
        return TopIcon(
          icon: s.status.vpn ? Icons.vpn_lock : Icons.vpn_lock_outlined,
          dim: !s.status.vpn,
          onPressed: () => Native.launch(app.package),
        );
    }
    return null;
  }
}

/// A top-bar icon. Focus brightens and enlarges it and puts a dot under it.
class TopIcon extends StatelessWidget {
  const TopIcon({super.key, required this.icon, required this.onPressed, this.dim = false, this.collapsed = false});

  final IconData icon;
  final VoidCallback onPressed;

  /// Drawn fainter, e.g. a VPN that is off.
  final bool dim;

  /// Takes no space until focused.
  final bool collapsed;

  @override
  Widget build(BuildContext context) => Pressable(
    onPressed: onPressed,
    builder: (context, focused) {
      final icon = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: focused ? 1.2 : 1,
              duration: Look.fast,
              curve: Look.ease,
              child: Icon(
                this.icon,
                size: 22,
                color: Look.white.withValues(alpha: focused ? 1 : (dim ? 0.5 : 0.8)),
                shadows: Look.shadow,
              ),
            ),
            const SizedBox(height: 7),
            AnimatedOpacity(
              opacity: focused ? 1 : 0,
              duration: Look.fast,
              child: const SizedBox.square(
                dimension: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Look.white, shape: BoxShape.circle),
                ),
              ),
            ),
          ],
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
    return Text('$hour:${now.minute.toString().padLeft(2, '0')}', style: Look.clock);
  }
}
