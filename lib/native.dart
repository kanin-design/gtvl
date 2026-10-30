import 'dart:convert';

import 'package:flutter/services.dart';

/// The Android side: installed apps, launching, and system events.
abstract final class Native {
  static const _main = MethodChannel('gtvl/main');
  static const _events = EventChannel('gtvl/events');

  /// One shared stream of events: {type: apps}, {type: network, kind, online,
  /// vpn, signal}, {type: home}, {type: buttons} when the button service turns
  /// on or off, {type: open, what} when a remapped button asks for GTVL's
  /// settings or all apps, {type: hdr, what} from the HDR video layer, and
  /// {type: update, what, message} from Android's installer.
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

  /// What other apps share with the home screen, as {watchNext: [...],
  /// channels: [...]}; null while GTVL may not read TV listings.
  static Future<Map<Object?, Object?>?> appRows() async {
    try {
      return await _main.invokeMapMethod<Object?, Object?>('appRows');
    } on PlatformException {
      return null;
    }
  }

  /// Asks the user to let GTVL read TV listings; true once it may.
  static Future<bool> allowTvListings() async => await _main.invokeMethod<bool>('allowTvListings') ?? false;

  /// A picture an app shares by its own address, as a small file; null if
  /// the app doesn't let GTVL read it.
  static Future<String?> picture(String address) async {
    try {
      return await _main.invokeMethod<String>('picture', address);
    } on PlatformException {
      return null;
    }
  }

  /// Opens [uri] in [package], e.g. a film in Plex; without that, the app itself.
  static Future<bool> open(String uri, {String? package}) async =>
      await _main.invokeMethod<bool>('open', {'uri': uri, 'package': package}) ?? false;

  static Future<void> appInfo(String package) => _main.invokeMethod('appInfo', package);

  static Future<void> uninstall(String package) => _main.invokeMethod('uninstall', package);

  /// Whether the button service is on, and the remotes connected now, with
  /// which of [keys] (Android's names for them) each one has, and whether it
  /// has sent GTVL a key (is [used]).
  static Future<({bool on, List<({String id, String name, List<String> keys, bool used})> remotes})> buttons(
    List<String> keys,
  ) async {
    final reply = await _main.invokeMapMethod<String, Object?>('buttons', keys) ?? const {};
    return (
      on: reply['on'] == true,
      remotes: [
        for (final remote in reply['remotes'] as List? ?? const [])
          if (remote case {'id': final String id, 'name': final String name, 'keys': final List<Object?> keys})
            (id: id, name: name, keys: keys.whereType<String>().toList(), used: remote['used'] == true),
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

  /// Plays an HDR film on the video layer beneath GTVL's screen (Android's
  /// HdrDeck), replacing anything there; [loop] plays it, and any queued
  /// after it, over and over.
  static Future<void> hdrPlay(String uri, {bool loop = false, double speed = 1}) =>
      _main.invokeMethod('hdrPlay', {'uri': uri, 'loop': loop, 'speed': speed});

  /// Changes how the HDR film playing, and any queued after it, play.
  static Future<void> hdrAdjust({required bool loop, required double speed}) =>
      _main.invokeMethod('hdrAdjust', {'loop': loop, 'speed': speed});

  /// Loads an HDR film to follow the one playing, without a gap.
  static Future<void> hdrQueue(String uri) => _main.invokeMethod('hdrQueue', uri);

  /// Moves on to the film queued next.
  static Future<void> hdrSkip() => _main.invokeMethod('hdrSkip');
  static Future<void> hdrPause() => _main.invokeMethod('hdrPause');
  static Future<void> hdrResume() => _main.invokeMethod('hdrResume');

  /// Lets go of the HDR video layer and its decoder.
  static Future<void> hdrStop() => _main.invokeMethod('hdrStop');

  /// Opens a system settings screen, e.g. "android.settings.WIFI_SETTINGS".
  static Future<void> openSettings([String? action]) => _main.invokeMethod('settings', action);

  /// This copy of GTVL, and what Android allows for its updates: [allowed]
  /// to install apps at all (the user's switch), and [quiet]: Android 12 or
  /// later, which updates GTVL without asking once that switch is on too.
  /// [room]: free bytes for a download.
  static Future<({String version, int build, List<String> abis, bool allowed, bool quiet, int room})>
  updateInfo() async {
    final info = await _main.invokeMapMethod<String, Object?>('updateInfo') ?? const {};
    return (
      version: info['version'] as String? ?? '',
      build: info['build'] as int? ?? 0,
      abis: [...?(info['abis'] as List?)?.whereType<String>()],
      allowed: info['allowed'] == true,
      quiet: info['quiet'] == true,
      room: info['room'] as int? ?? 0,
    );
  }

  /// Why the downloaded update at [path] must not be installed: "size",
  /// "checksum", "unreadable", "package", "older", "android" or "signer"
  /// (see Updater.check). Null if it may.
  static Future<String?> checkUpdate(String path, {required int size, required String sha256}) =>
      _main.invokeMethod<String>('checkUpdate', {'path': path, 'size': size, 'sha256': sha256});

  /// Hands the checked update at [path] to Android's installer, which asks
  /// the user unless GTVL may update itself. Its answers come as events,
  /// {type: update, what, message}; once it's in, GTVL starts again.
  static Future<void> installUpdate(String path) => _main.invokeMethod('installUpdate', path);

  /// Has the checked update at [path] install as the TV next goes to
  /// standby, without asking; null calls that off.
  static Future<void> updateAtStandby(String? path) => _main.invokeMethod('updateAtStandby', path);

  /// Opens Android's switch that lets GTVL install apps, for its own updates.
  static Future<bool> allowUpdates() async => await _main.invokeMethod<bool>('allowUpdates') ?? false;
}
