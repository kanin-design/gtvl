import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Everything the user can change, kept in one JSON file (config.json).
///
/// Unknown or mistyped values fall back to their defaults one by one, so a
/// hand-edited file never loses the rest. Saves happen shortly after a change,
/// atomically (temp file, then rename), keeping the previous file as .bak.
class Config extends ChangeNotifier {
  Config._(this._dir, Map<String, Object?> json, {required this.isNew})
    : dock = _strings(json['dock']),
      hidden = {..._strings(json['hidden'])},
      wallpaper = _get<String>(json, 'wallpaper') ?? 'aerials',
      aerialQuality = _get<String>(json, 'aerialQuality') ?? '1080p',
      gradient = _get<int>(json, 'gradient') ?? 0,
      videoPath = _get<String>(json, 'videoPath'),
      imagePath = _get<String>(json, 'imagePath'),
      topIcons = _iconOrder(_strings(json['topIcons'])),
      topHidden = {..._strings(json['topHidden'])},
      vpnApp = _get<String>(json, 'vpnApp'),
      clock24 = _get<bool>(json, 'clock24') ?? true,
      blur = _get<bool>(json, 'blur') ?? true;

  /// Icons the top bar can show, in their default order.
  static const topIconIds = ['settings', 'network', 'vpn'];

  final String _dir;

  /// No config file existed: this is the first start.
  final bool isNew;

  /// Favourite apps in the dock, in order.
  final List<String> dock;
  final Set<String> hidden;

  /// aerials, gradient, video or image.
  String wallpaper;
  String aerialQuality;
  int gradient;
  String? videoPath;
  String? imagePath;

  final List<String> topIcons;
  final Set<String> topHidden;
  String? vpnApp;
  bool clock24;

  /// Frosted glass; off draws plain tints, for slow GPUs.
  bool blur;

  Timer? _save;

  static Future<Config> load(String dir) async {
    for (final name in const ['config.json', 'config.json.bak']) {
      final file = File('$dir/$name');
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, Object?>) return Config._(dir, json, isNew: false);
      } on FormatException {
        // Unreadable: try the backup, then start from defaults.
      }
    }
    return Config._(dir, const {}, isNew: true);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'dock': dock,
    'hidden': hidden.toList(),
    'wallpaper': wallpaper,
    'aerialQuality': aerialQuality,
    'gradient': gradient,
    'videoPath': videoPath,
    'imagePath': imagePath,
    'topIcons': topIcons,
    'topHidden': topHidden.toList(),
    'vpnApp': vpnApp,
    'clock24': clock24,
    'blur': blur,
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

  static T? _get<T>(Map<String, Object?> json, String key) => json[key] is T ? json[key] as T : null;

  static List<String> _strings(Object? value) => value is List
      ? [
          for (final v in value)
            if (v is String) v,
        ]
      : [];

  /// The saved icon order without unknown ids, plus icons added since.
  static List<String> _iconOrder(List<String> saved) => [
    ...saved.where(topIconIds.contains),
    ...topIconIds.where((id) => !saved.contains(id)),
  ];
}
