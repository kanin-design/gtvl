import 'dart:async';

import 'package:flutter/widgets.dart';

import 'aerials.dart';
import 'apps.dart';
import 'channels.dart';
import 'config.dart';
import 'native.dart';
import 'plex.dart';
import 'status.dart';
import 'updates.dart';

/// Everything the UI shares, created once at start.
class Services {
  Services._(this.files, this.config, this.apps, this.status, this.aerials, this.plex, this.appRows, this.updates);

  /// The app's private folder, where downloaded wallpapers are kept.
  final String files;

  final Config config;
  final AppsModel apps;
  final StatusModel status;
  final Aerials aerials;

  /// Rows of things to watch from the user's Plex account.
  final Plex plex;

  /// Rows other apps share with the home screen.
  final AppRows appRows;

  /// New versions of GTVL, from its GitHub releases.
  final Updates updates;

  /// What the wallpaper shows now, e.g. "Hawaii · Pu'u O 'Umi"; null when nothing to say.
  final caption = ValueNotifier<String?>(null);

  /// An HDR film plays on the video layer beneath the screen, which then
  /// leaves the wallpaper's place see-through.
  final hdrBeneath = ValueNotifier(false);

  /// A short line about something that didn't happen ("Couldn't open
  /// Plex"), shown above the dock for a few seconds.
  final notice = Notice();

  static Future<Services> start() async {
    // Asked first: listing the TV's decoders takes a moment.
    final hdr = Native.hdr();
    final paths = await Native.paths();
    final config = await Config.load(paths.files);
    Native.remap(config.remotes);
    final aerials = Aerials('${paths.cache}/aerial', hdr: await hdr);
    await aerials.load();
    final apps = AppsModel(config)..load();
    final plex = Plex(paths.files)..load();
    final updates = Updates(config, paths.cache)..start();
    return Services._(paths.files, config, apps, StatusModel(config), aerials, plex, AppRows()..refresh(), updates);
  }

  static Services of(BuildContext context) => context.getInheritedWidgetOfExactType<Scope>()!.services;
}

/// A line for the user that clears itself after a few seconds.
class Notice extends ValueNotifier<String?> {
  Notice() : super(null);

  Timer? _clear;

  void show(String text) {
    _clear?.cancel();
    value = text;
    _clear = Timer(const Duration(seconds: 4), () => value = null);
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }
}

/// Makes [Services] available below it. Never changes, so never rebuilds.
class Scope extends InheritedWidget {
  const Scope({super.key, required this.services, required super.child});

  final Services services;

  @override
  bool updateShouldNotify(Scope oldWidget) => false;
}
