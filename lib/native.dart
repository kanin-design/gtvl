import 'dart:convert';

import 'package:flutter/services.dart';

/// The Android side: installed apps, launching, and system events.
abstract final class Native {
  static const _main = MethodChannel('gtvl/main');
  static const _events = EventChannel('gtvl/events');

  /// One shared stream of events: {type: apps}, {type: network, kind, online,
  /// vpn, signal}, {type: home}, {type: buttons} when the button service turns
  /// on or off, and {type: open, what} when a remapped button asks for
  /// GTVL's settings or all apps.
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

  /// Storage to pick pictures or [videos] from (the TV's own and any USB
  /// drives), once the user allows reading them; null if they do not.
  static Future<List<({String path, String name})>?> storage({bool videos = false}) async {
    final volumes = await _main.invokeListMethod<Map<Object?, Object?>>('storage', videos ? 'videos' : 'pictures');
    return volumes == null ? null : [for (final v in volumes) (path: v['path']! as String, name: v['name']! as String)];
  }

  /// A small JPEG of a frame from the video at [path], made once; null if the
  /// video can't be read.
  static Future<String?> videoFrame(String path) async {
    try {
      return await _main.invokeMethod<String>('videoFrame', path);
    } on PlatformException {
      return null;
    }
  }

  /// Whether this TV can decode the video at [path]; true when that can't be
  /// told, so the player tries.
  static Future<bool> canPlay(String path) async {
    try {
      return await _main.invokeMethod<bool>('canPlay', path) ?? true;
    } on PlatformException {
      return true;
    }
  }

  /// Whether the video at [path] is HDR (Dolby Vision, HDR10 or HLG), which
  /// shows right only on the TV's own video surface.
  static Future<bool> isHdr(String path) async {
    try {
      return await _main.invokeMethod<bool>('isHdr', path) ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// The HDR aerial qualities this TV can show: the films are Dolby Vision,
  /// which needs a decoder for it and a screen that takes it.
  static Future<Set<String>> hdr() async {
    try {
      return {...?await _main.invokeListMethod<String>('hdr')};
    } on PlatformException {
      return const {}; // unknown: SDR only
    }
  }

  /// Launchable VPN apps as {package, name}.
  static Future<List<Map<Object?, Object?>>> vpnApps() async =>
      await _main.invokeListMethod<Map<Object?, Object?>>('vpnApps') ?? const [];

  static Future<bool> launch(String package) async => await _main.invokeMethod<bool>('launch', package) ?? false;

  static Future<void> appInfo(String package) => _main.invokeMethod('appInfo', package);

  static Future<void> uninstall(String package) => _main.invokeMethod('uninstall', package);

  /// Whether the button service is on, and the remotes connected now, with
  /// which of [keys] (Android's names for them) each one has.
  static Future<({bool on, List<({String id, String name, List<String> keys})> remotes})> buttons(
    List<String> keys,
  ) async {
    final reply = await _main.invokeMapMethod<String, Object?>('buttons', keys) ?? const {};
    return (
      on: reply['on'] == true,
      remotes: [
        for (final remote in reply['remotes'] as List? ?? const [])
          if (remote case {'id': final String id, 'name': final String name, 'keys': final List<Object?> keys})
            (id: id, name: name, keys: keys.whereType<String>().toList()),
      ],
    );
  }

  /// Hands the button service the remaps, as Config.remotes keeps them.
  static Future<void> remap(Map<String, Object?> remotes) => _main.invokeMethod('remap', jsonEncode(remotes));

  /// The next button pressed on any remote; null if none comes in a while,
  /// or Back is pressed, or the service is off.
  static Future<({String remote, String name, String key})?> findButton() async =>
      switch (await _main.invokeMapMethod<String, Object?>('findButton')) {
        {'remote': final String remote, 'name': final String name, 'key': final String key} => (
          remote: remote,
          name: name,
          key: key,
        ),
        _ => null,
      };

  static Future<void> stopFinding() => _main.invokeMethod('stopFinding');

  /// Opens Android's switch for the button service, or the nearest settings
  /// page the TV has.
  static Future<void> buttonSettings() => _main.invokeMethod('buttonSettings');

  /// Opens a system settings screen, e.g. "android.settings.WIFI_SETTINGS".
  static Future<void> openSettings([String? action]) => _main.invokeMethod('settings', action);
}
