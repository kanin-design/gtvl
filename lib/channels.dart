import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'native.dart';
import 'shows.dart';

/// Rows other apps share with the home screen, as Android's TV listings
/// hold them: what is being watched in each app, and each app's own
/// channels. Reading them takes the TV listings permission, which the user
/// grants once; they refresh whenever GTVL comes back to the front.
class AppRows extends ChangeNotifier {
  AppRows() {
    _lifecycle = AppLifecycleListener(onResume: refresh);
  }

  late final AppLifecycleListener _lifecycle;

  /// False until GTVL may read TV listings.
  bool allowed = false;

  /// Each app's Continue watching row, the app watched last first.
  List<ShowRowData> watching = const [];

  /// The channels apps share, such as their recommendations.
  List<ShowRowData> channels = const [];

  Future<void> refresh() async {
    final shared = await Native.appRows();
    allowed = shared != null;
    watching = _watching(shared?['watchNext']);
    channels = _channels(shared?['channels']);
    notifyListeners();
  }

  /// Asks Android to let GTVL read TV listings; the user answers on the TV.
  Future<void> allow() async {
    await Native.allowTvListings();
    await refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  static List<ShowRowData> _watching(Object? programs) {
    final byApp = <String, List<(int, ShowItem)>>{};
    final names = <String, String>{};
    for (final program in programs is List ? programs : const []) {
      final item = _item(program);
      if (item == null) continue;
      final time = program['time'] is int ? program['time'] as int : 0;
      byApp.putIfAbsent(item.app, () => []).add((time, item));
      names[item.app] = program['appName'] is String ? program['appName'] as String : item.app;
    }
    int newest(List<(int, ShowItem)> items) => items.fold(0, (latest, entry) => entry.$1 > latest ? entry.$1 : latest);
    return [
      for (final MapEntry(key: app, value: items)
          in byApp.entries.toList()..sort((a, b) => newest(b.value) - newest(a.value)))
        (
          id: 'tv.next.$app',
          title: 'Continue watching',
          source: names[app]!,
          items: [for (final (_, item) in items..sort((a, b) => b.$1 - a.$1)) item].take(20).toList(),
        ),
    ];
  }

  static List<ShowRowData> _channels(Object? channels) => [
    for (final channel in channels is List ? channels : const [])
      if (channel case {
        'app': final String app,
        'appName': final String appName,
        'name': final String name,
        'programs': final List<Object?> programs,
      })
        if ([for (final program in programs) ?_item(program)] case final items when items.isNotEmpty)
          (id: 'tv.channel.$app.$name', title: name, source: appName, items: items),
  ];

  static ShowItem? _item(Object? program) {
    if (program case {'title': final String title, 'link': final String link, 'app': final String app}) {
      String? text(String key) => program[key] is String ? program[key] as String : null;
      return ShowItem(
        title: title,
        link: link,
        app: app,
        subtitle: text('subtitle'),
        summary: text('summary'),
        image: text('image'),
        progress: program['progress'] is num ? (program['progress'] as num).toDouble() : null,
        minutesLeft: program['minutesLeft'] is int ? program['minutesLeft'] as int : null,
      );
    }
    return null;
  }
}
