import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'native.dart';

class AppInfo {
  AppInfo(this.package, this.label, {required this.tv, required this.version});

  final String package;
  final String label;

  /// Has a TV (leanback) entry, so usually a banner.
  final bool tv;

  /// Last update time: a changed app gets a fresh tile.
  final int version;

  Future<String?>? _tile, _icon;

  /// Set once [tile] or [icon] has loaded, so tiles that are ready draw on the
  /// first frame.
  String? tilePath, iconPath;

  /// The cached tile image: a TV banner (".b.png") or an icon (".i.png").
  Future<String?> get tile => _tile ??= Native.tile(package).then((path) => tilePath = path);

  /// The app's icon filling a square (".s.png"), for rounded-square tiles.
  Future<String?> get icon => _icon ??= Native.icon(package).then((path) => iconPath = path);
}

/// The installed apps, split into the dock (favourites, in the user's
/// order), all other apps, and hidden ones.
class AppsModel extends ChangeNotifier {
  AppsModel(this._config) {
    // An install sends several package events at once: reload once after them.
    Native.events.where((event) => event['type'] == 'apps').listen((_) {
      _reload?.cancel();
      _reload = Timer(const Duration(milliseconds: 300), load);
    });
  }

  final Config _config;
  Timer? _reload;
  Map<String, AppInfo> _apps = const {};
  bool loaded = false;

  /// System settings apps make poor default favourites.
  static const _notDefaults = {'com.android.tv.settings', 'com.android.settings'};

  List<AppInfo> get dock => [for (final package in _config.dock) ?_apps[package]];

  List<AppInfo> get others => [
    for (final app in _apps.values)
      if (!_config.dock.contains(app.package) && !_config.hidden.contains(app.package)) app,
  ];

  List<AppInfo> get hidden => [for (final package in _config.hidden) ?_apps[package]];

  Future<void> load() async {
    final found = [
      for (final m in await Native.apps())
        AppInfo(m['package']! as String, m['label']! as String, tv: m['tv'] == true, version: m['version']! as int),
    ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    if (found.isEmpty) return; // a failed query must never empty the dock
    final old = _apps;
    // Unchanged apps keep their loaded tiles.
    _apps = {for (final app in found) app.package: old[app.package]?.version == app.version ? old[app.package]! : app};

    var configChanged = false;
    if (!loaded && _config.isNew && _config.dock.isEmpty) {
      // First start: TV apps have banners and make a good dock.
      _config.dock.addAll(found.where((a) => a.tv && !_notDefaults.contains(a.package)).take(6).map((a) => a.package));
      configChanged = true;
    }
    final before = _config.dock.length + _config.hidden.length;
    _config.dock.removeWhere((package) => !_apps.containsKey(package));
    _config.hidden.removeWhere((package) => !_apps.containsKey(package));
    if (configChanged || _config.dock.length + _config.hidden.length != before) _config.changed();

    loaded = true;
    notifyListeners();
  }

  bool inDock(String package) => _config.dock.contains(package);

  void toggleDock(String package) {
    if (!_config.dock.remove(package)) _config.dock.add(package);
    _changed();
  }

  void hide(String package) {
    _config.dock.remove(package);
    _config.hidden.add(package);
    _changed();
  }

  void unhide(String package) {
    _config.hidden.remove(package);
    _changed();
  }

  /// Moves a dock app [by] places, staying inside the dock.
  void move(String package, int by) {
    final dock = _config.dock;
    final from = dock.indexOf(package);
    final to = from + by;
    if (from < 0 || to < 0 || to >= dock.length) return;
    dock
      ..removeAt(from)
      ..insert(to, package);
    _changed();
  }

  void _changed() {
    _config.changed();
    notifyListeners();
  }
}
