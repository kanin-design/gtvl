import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Everything the user can change, kept in one JSON file (config.json) over
/// the defaults that ship with the app (assets/defaults.json, the same shape).
///
/// A missing or mistyped value falls back to its default on its own, so a
/// hand-edited file never loses the rest. Saves happen shortly after a change,
/// atomically (temp file, then rename), keeping the previous file as .bak.
class Config extends ChangeNotifier {
  Config._(this._dir, _Values v, {required this.isNew})
    : dock = v.strings('dock'),
      hidden = {...v.strings('hidden')},
      wallpaper = v.get('wallpaper'),
      aerialQuality = v.get('aerialQuality'),
      gradient = v.get('gradient'),
      pictures = v.stringsOr('pictures', 'imagePath'),
      pictureMinutes = v.get('pictureMinutes'),
      pictureShuffle = v.get('pictureShuffle'),
      videos = v.stringsOr('videos', 'videoPath'),
      videoShuffle = v.get('videoShuffle'),
      videoLoopMinutes = v.get('videoLoopMinutes'),
      topIcons = _iconOrder(v.strings('topIcons')),
      topHidden = {...v.strings('topHidden')},
      vpnApp = v.get('vpnApp'),
      clock24 = v.get('clock24'),
      showCaption = v.get('showCaption'),
      aerialsOff = {...v.strings('aerialsOff')},
      aerialSpeed = v.number('aerialSpeed'),
      aerialMinutes = v.get('aerialMinutes'),
      aerialCache = v.get('aerialCache'),
      dimming = v.number('dimming'),
      glassBlur = v.number('glassBlur'),
      glassTint = v.get('glassTint'),
      glassTintAlpha = v.number('glassTintAlpha'),
      lineWidth = v.number('lineWidth'),
      lineAlpha = v.number('lineAlpha'),
      dockSize = _dockSize(v.get('dockSize')),
      dockSpacing = v.number('dockSpacing'),
      tileCorners = v.number('tileCorners'),
      dockRoom = v.number('dockRoom'),
      dockNames = v.get('dockNames'),
      tileShape = v.get('tileShape'),
      dockAlign = v.get('dockAlign'),
      glow = v.get('glow'),
      remotes = v.map('remotes'),
      showsOff = {...v.strings('showsOff')},
      autoUpdate = v.get('autoUpdate');

  /// Icons the top bar can show, in their default order.
  static const topIconIds = ['settings', 'network', 'vpn'];

  final String _dir;

  /// No config file existed: this is the first start.
  final bool isNew;

  /// Favourite apps in the dock, in order.
  final List<String> dock;
  final Set<String> hidden;

  /// aerials, gradient, video or image (pictures).
  String wallpaper;
  String aerialQuality;
  int gradient;

  /// Pictures shown in turn: picture files, and folders standing for every
  /// picture in them.
  final List<String> pictures;

  /// With several pictures, the next shows after this many minutes.
  int pictureMinutes;
  bool pictureShuffle;

  /// Videos played in turn, chosen like [pictures]; a single one loops.
  final List<String> videos;
  bool videoShuffle;

  /// With several videos, each loops this many minutes before the next; 0
  /// plays each once.
  int videoLoopMinutes;

  final List<String> topIcons;
  final Set<String> topHidden;
  String? vpnApp;
  bool clock24;

  /// The wallpaper's location, under the clock.
  bool showCaption;

  /// Aerial scene kinds turned off (see Aerials.kinds).
  final Set<String> aerialsOff;
  double aerialSpeed;

  /// Move on to the next film after this many minutes; 0 plays each to its end.
  int aerialMinutes;

  /// Keep one film on the TV for an instant start.
  bool aerialCache;

  /// Darkens the wallpaper, 0 to 1.
  double dimming;

  /// The dock's glass: blur radius (0 for none), tint colour and strength, and
  /// the lines along its edges (width 0 for none).
  double glassBlur;
  int glassTint;
  double glassTintAlpha;
  double lineWidth;
  double lineAlpha;

  /// xs, s, m, l or xl: how big the dock and app tiles are.
  String dockSize;

  /// The space between apps, how round their corners are, and the room
  /// above and below them in the dock, each as a factor of the usual (1).
  double dockSpacing;
  double tileCorners;
  double dockRoom;

  /// The name of the dock app in focus shows under it.
  bool dockNames;

  /// wide (TV banners) or square (icons in rounded squares).
  String tileShape;

  /// How the dock spreads its apps when they fit: start, center, evenly
  /// (equal gaps, ends too) or between (first and last at the edges).
  String dockAlign;

  /// How strongly the glass glows behind the dock app in focus: a step of
  /// GlowLook.steps, 0 the faintest.
  int glow;

  /// What the remote's buttons do instead, by remote (see Remaps).
  final Map<String, Object?> remotes;

  /// Rows of things to watch turned off (see Plex.rowNames).
  final Set<String> showsOff;

  /// Look for new versions of GTVL every few hours and get them ready; where
  /// Android allows, install them at standby (see Updates).
  bool autoUpdate;

  Timer? _save;

  static Future<Config> load(String dir) async {
    final defaults = jsonDecode(await rootBundle.loadString('assets/defaults.json')) as Map<String, Object?>;
    for (final name in const ['config.json', 'config.json.bak']) {
      final file = File('$dir/$name');
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) return Config._(dir, _Values(json, defaults), isNew: false);
      } on Exception {
        // Unreadable (not JSON, not UTF-8, a read error): try the backup, then start from defaults.
      }
    }
    return Config._(dir, _Values(const {}, defaults), isNew: true);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'dock': dock,
    'hidden': hidden.toList(),
    'wallpaper': wallpaper,
    'aerialQuality': aerialQuality,
    'gradient': gradient,
    'pictures': pictures,
    'pictureMinutes': pictureMinutes,
    'pictureShuffle': pictureShuffle,
    'videos': videos,
    'videoShuffle': videoShuffle,
    'videoLoopMinutes': videoLoopMinutes,
    'topIcons': topIcons,
    'topHidden': topHidden.toList(),
    'vpnApp': vpnApp,
    'clock24': clock24,
    'showCaption': showCaption,
    'aerialsOff': aerialsOff.toList(),
    'aerialSpeed': aerialSpeed,
    'aerialMinutes': aerialMinutes,
    'aerialCache': aerialCache,
    'dimming': dimming,
    'glassBlur': glassBlur,
    'glassTint': glassTint,
    'glassTintAlpha': glassTintAlpha,
    'lineWidth': lineWidth,
    'lineAlpha': lineAlpha,
    'dockSize': dockSize,
    'dockSpacing': dockSpacing,
    'tileCorners': tileCorners,
    'dockRoom': dockRoom,
    'dockNames': dockNames,
    'tileShape': tileShape,
    'dockAlign': dockAlign,
    'glow': glow,
    'remotes': remotes,
    'showsOff': showsOff.toList(),
    'autoUpdate': autoUpdate,
  };

  /// Call after changing any field: tells listeners and saves soon.
  void changed() {
    notifyListeners();
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 500), _write);
  }

  Future<void> _write() async {
    final file = File('$_dir/config.json');
    final temp = File('$_dir/config.json.tmp');
    try {
      await temp.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()), flush: true);
      if (await file.exists()) await file.rename('$_dir/config.json.bak');
      await temp.rename(file.path);
    } on FileSystemException catch (e) {
      debugPrint('Could not save config: $e');
    }
  }

  /// Sizes were small, medium and large, and small already looked medium:
  /// each keeps its look under its new name.
  static String _dockSize(String saved) => const {'small': 'm', 'medium': 'l', 'large': 'xl'}[saved] ?? saved;

  /// The saved icon order without unknown ids, plus icons added since.
  static List<String> _iconOrder(List<String> saved) => [
    ...saved.where(topIconIds.contains),
    ...topIconIds.where((id) => !saved.contains(id)),
  ];
}

/// Saved values over the defaults: each key takes its saved value when that
/// has the right type, else its default.
class _Values {
  _Values(this.saved, this.defaults);

  final Map<String, Object?> saved, defaults;

  /// A saved null counts only when it was saved on purpose.
  T get<T>(String key) => switch ((saved[key], defaults[key])) {
    (final T value, _) when value != null || saved.containsKey(key) => value,
    (_, final T value) => value,
    _ => throw StateError('defaults.json has no $key'),
  };

  /// JSON writes 24.0 as 24, so any number counts.
  double number(String key) => switch ((saved[key], defaults[key])) {
    (final num value, _) || (_, final num value) => value.toDouble(),
    _ => throw StateError('defaults.json has no $key'),
  };

  /// A list of strings, without anything else in it.
  List<String> strings(String key) => [
    for (final value in saved[key] is List ? saved[key]! as List : defaults[key] as List? ?? const [])
      if (value is String) value,
  ];

  /// A JSON object, as saved, else a copy of its default.
  Map<String, Object?> map(String key) => switch ((saved[key], defaults[key])) {
    (final Map<String, Object?> value, _) => value,
    (_, final Map<String, Object?> value) => {...value},
    _ => throw StateError('defaults.json has no $key'),
  };

  /// [strings], from a file saved before the list replaced the single path
  /// under [old].
  List<String> stringsOr(String key, String old) =>
      saved[key] is! List && saved[old] is String ? [saved[old]! as String] : strings(key);
}
