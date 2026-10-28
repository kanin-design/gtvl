import 'package:flutter/services.dart';

/// The Android side: installed apps, launching, and system events.
abstract final class Native {
  static const _main = MethodChannel('gtvl/main');
  static const _events = EventChannel('gtvl/events');

  /// One shared stream of events: {type: apps}, {type: network, kind, online,
  /// vpn, signal} and {type: home}.
  static final Stream<Map<Object?, Object?>> events = _events.receiveBroadcastStream().map(
    (event) => event as Map<Object?, Object?>,
  );

  static Future<({String files, String cache})> paths() async {
    final paths = (await _main.invokeMapMethod<String, String>('paths'))!;
    return (files: paths['files']!, cache: paths['cache']!);
  }

  /// Launchable apps as {package, label, tv, version}.
  static Future<List<Map<Object?, Object?>>> apps() async =>
      await _main.invokeListMethod<Map<Object?, Object?>>('apps') ?? const [];

  /// Path of the app's cached tile: a TV banner (".b.png") or an icon (".i.png").
  static Future<String?> tile(String package) => _main.invokeMethod<String>('tile', package);

  /// Path of the app's icon filling a square (".s.png"), for rounded-square tiles.
  static Future<String?> icon(String package) => _main.invokeMethod<String>('icon', package);

  /// Storage to pick pictures from (the TV's own and any USB drives), once the
  /// user allows reading pictures; null if they do not.
  static Future<List<({String path, String name})>?> storage() async {
    final volumes = await _main.invokeListMethod<Map<Object?, Object?>>('storage');
    return volumes == null ? null : [for (final v in volumes) (path: v['path']! as String, name: v['name']! as String)];
  }

  /// Launchable VPN apps as {package, name}.
  static Future<List<Map<Object?, Object?>>> vpnApps() async =>
      await _main.invokeListMethod<Map<Object?, Object?>>('vpnApps') ?? const [];

  static Future<bool> launch(String package) async => await _main.invokeMethod<bool>('launch', package) ?? false;

  static Future<void> appInfo(String package) => _main.invokeMethod('appInfo', package);

  static Future<void> uninstall(String package) => _main.invokeMethod('uninstall', package);

  /// Opens a system settings screen, e.g. "android.settings.WIFI_SETTINGS".
  static Future<void> openSettings([String? action]) => _main.invokeMethod('settings', action);
}
