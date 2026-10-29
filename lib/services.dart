import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'apps.dart';
import 'config.dart';
import 'native.dart';
import 'status.dart';

/// Everything the UI shares, created once at start.
class Services {
  Services._(this.files, this.config, this.apps, this.status, this.aerials);

  /// The app's private folder, where downloaded wallpapers are kept.
  final String files;

  final Config config;
  final AppsModel apps;
  final StatusModel status;
  final Aerials aerials;

  /// What the wallpaper shows now, e.g. "Hawaii · Pu'u O 'Umi"; null when nothing to say.
  final caption = ValueNotifier<String?>(null);

  static Future<Services> start() async {
    // Asked first: listing the TV's decoders takes a moment.
    final hdr = Native.hdr();
    final paths = await Native.paths();
    final config = await Config.load(paths.files);
    Native.remap(config.remotes);
    final aerials = Aerials('${paths.cache}/aerial', hdr: await hdr);
    await aerials.load();
    final apps = AppsModel(config)..load();
    return Services._(paths.files, config, apps, StatusModel(config), aerials);
  }

  static Services of(BuildContext context) => context.getInheritedWidgetOfExactType<Scope>()!.services;
}

/// Makes [Services] available below it. Never changes, so never rebuilds.
class Scope extends InheritedWidget {
  const Scope({super.key, required this.services, required super.child});

  final Services services;

  @override
  bool updateShouldNotify(Scope oldWidget) => false;
}
