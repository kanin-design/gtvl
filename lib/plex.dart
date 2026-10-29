import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'shows.dart';

typedef _Server = ({String uri, String token, String id});

/// An item as fetched: the time it sorts by, its id across servers, the item.
typedef _Found = (int, String, ShowItem);

/// Plex: signed in once with a code at plex.tv/link, then rows of what to
/// watch from every server the account reaches, refreshed whenever GTVL
/// comes back to the front.
///
/// The account's token stays on the TV, in plex.json beside config.json.
class Plex extends ChangeNotifier {
  Plex(this._dir);

  final String _dir;

  /// The Plex app, which opens what a row shows.
  static const app = 'com.plexapp.android';

  /// Rows as their ids and titles, in the order they show.
  static const rowNames = [('plex.continue', 'Continue watching'), ('plex.recent', 'Recently added')];

  /// This TV, as Plex lists it among the account's devices.
  String _clientId = '';
  String? _token;

  /// The account's name, once signed in.
  String? user;

  List<ShowRowData> rows = const [];

  /// Servers that answered, and through which connection; null while any of
  /// the account's servers has yet to answer.
  List<_Server>? _servers;
  bool _refreshing = false;

  /// Bumped on every sign-in and sign-out, so a refresh still running from
  /// before it changes nothing.
  int _account = 0;

  /// The code waiting to be entered, and the wait for it.
  int? _pin;
  Future<bool>? _waiting;
  AppLifecycleListener? _lifecycle;

  bool get signedIn => _token != null;

  File get _file => File('$_dir/plex.json');

  /// Reads the saved account, if any, and fetches its rows.
  Future<void> load() async {
    try {
      final saved = jsonDecode(await _file.readAsString());
      if (saved case {'clientId': final String id}) _clientId = id;
      if (saved case {'token': final String token}) _token = token;
      if (saved case {'user': final String name}) user = name;
      if (saved case {'servers': final List<Object?> servers}) {
        final found = [
          for (final s in servers)
            if (s case {'uri': final String uri, 'token': final String token, 'id': final String id})
              (uri: uri, token: token, id: id),
        ];
        // None saved: they are looked for again.
        if (found.isNotEmpty) _servers = found;
      }
    } on Object {
      // Never signed in.
    }
    if (_clientId.isEmpty) {
      final random = Random.secure();
      _clientId = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      // Plex ties a sign-in code to this id, so it must outlive a restart.
      await _save();
    }
    _lifecycle = AppLifecycleListener(onResume: refresh);
    unawaited(refresh());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'clientId': _clientId,
        'token': ?_token,
        'user': ?user,
        // Where each server answered, so the next start needn't look again.
        if (_servers case final servers? when servers.isNotEmpty)
          'servers': [
            for (final s in servers) {'uri': s.uri, 'token': s.token, 'id': s.id},
          ],
      }),
      flush: true,
    );
    await temp.rename(_file.path);
  }

  /// Starts signing in, and gives the code to enter at plex.tv/link. Plex is
  /// asked about the code in the background until it is used or runs out,
  /// so leaving the page doesn't lose the sign-in.
  Future<String> startSignIn() async {
    final pin = await _send('POST', 'https://plex.tv/api/v2/pins?strong=false');
    if (pin case {'id': final int id, 'code': final String code}) {
      _pin = id;
      _waiting = _waitFor(id);
      debugPrint('Plex: waiting for the code');
      return code;
    }
    throw const FormatException('Plex sent no code');
  }

  /// Completes true once the latest code is used, false once it runs out.
  Future<bool> get signIn => _waiting ?? Future.value(false);

  /// Asks Plex every 2 s whether code [pin] was entered; a newer code ends
  /// this wait.
  Future<bool> _waitFor(int pin) async {
    final until = DateTime.now().add(const Duration(minutes: 15));
    while (pin == _pin && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (pin != _pin) break;
      try {
        if (await _send('GET', 'https://plex.tv/api/v2/pins/$pin') case {
          'authToken': final String token,
        } when token.isNotEmpty) {
          final account = await _send('GET', 'https://plex.tv/api/v2/user', token: token);
          _account++;
          _token = token;
          _servers = null;
          user = switch (account) {
            {'title': final String title} when title.isNotEmpty => title,
            {'username': final String name} => name,
            _ => null,
          };
          _pin = null;
          await _save();
          debugPrint('Plex: signed in');
          notifyListeners();
          unawaited(refresh());
          return true;
        }
      } on Exception catch (e) {
        // Offline for a moment: keep waiting.
        debugPrint('Plex: still waiting ($e)');
      }
    }
    debugPrint('Plex: the code ran out');
    return false;
  }

  Future<void> signOut() async {
    _account++;
    _token = user = null;
    _servers = null;
    rows = const [];
    await _save();
    notifyListeners();
  }

  /// Fetches the rows again from every server that answers.
  Future<void> refresh() async {
    if (_token == null || _refreshing) return;
    _refreshing = true;
    final account = _account;
    try {
      var servers = _servers;
      if (servers == null) {
        final (found, all) = await _findServers();
        if (account != _account) return;
        servers = found;
        // A server asleep or restarting is looked for again next time.
        _servers = all && found.isNotEmpty ? found : null;
        await _save();
      }
      final watching = <_Found>[];
      final added = <_Found>[];
      var failed = false;
      // A server that fails leaves the others' items in place, and is looked
      // for again next time.
      await Future.wait([
        for (final server in servers)
          _fetch(server, watching, added).catchError((Object e) {
            failed = true;
            debugPrint('Plex: ${server.id}: $e');
          }),
      ]);
      if (account != _account) return;
      if (failed) _servers = null;
      debugPrint('Plex: ${servers.length} servers, ${watching.length} watching, ${added.length} added');
      // Newest first; a film or episode on two servers shows once.
      List<ShowItem> newest(List<_Found> items) {
        final seen = <String>{};
        return [
          for (final (_, id, item) in items..sort((a, b) => b.$1 - a.$1))
            if (seen.add(id)) item,
        ].take(20).toList();
      }

      rows = [
        (id: rowNames[0].$1, title: rowNames[0].$2, source: 'Plex', items: newest(watching)),
        (id: rowNames[1].$1, title: rowNames[1].$2, source: 'Plex', items: newest(added)),
      ];
      notifyListeners();
    } on _SignedOut {
      if (account == _account) await signOut();
    } on Object catch (e) {
      debugPrint('Plex: $e');
      if (account == _account) _servers = null; // look for them again next time
    } finally {
      _refreshing = false;
    }
  }

  /// The account's servers that answer, each through its nearest connection
  /// (on this network, then over the internet, then through Plex's relay),
  /// and whether all of them did.
  Future<(List<_Server>, bool)> _findServers() async {
    final resources = await _send('GET', 'https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1');
    debugPrint('Plex: ${resources is List ? resources.length : 0} devices on the account');
    final answers = await Future.wait([
      for (final resource in resources is List ? resources : const [])
        if (resource case {
          'provides': final String provides,
          'name': final String name,
          'clientIdentifier': final String id,
          'accessToken': final String token,
          'connections': final List<Object?> connections,
        } when provides.contains('server'))
          _nearest(name, id, token, connections),
    ]);
    return ([for (final server in answers) ?server], !answers.contains(null));
  }

  /// Server [id] through its nearest connection that answers, all of them
  /// tried at once; null when none does.
  Future<_Server?> _nearest(String name, String id, String token, List<Object?> connections) async {
    int rank(Map<Object?, Object?> c) => c['relay'] == true ? 2 : (c['local'] == true ? 0 : 1);
    final uris = [
      for (final c in connections.whereType<Map<Object?, Object?>>().toList()..sort((a, b) => rank(a) - rank(b)))
        if (c['uri'] case final String uri) uri,
    ];
    final answers = await Future.wait(uris.map((uri) => _answers(uri, token)));
    final i = answers.indexOf(true);
    debugPrint(
      'Plex: server $name: ${i >= 0 ? 'way ${i + 1} of ${uris.length} answers' : 'none of ${uris.length} answer'}',
    );
    return i >= 0 ? (uri: uris[i], token: token, id: id) : null;
  }

  /// Whether [uri] answers at all: any reply will do, whatever its form.
  Future<bool> _answers(String uri, String token) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(Uri.parse('$uri/identity'));
      request.headers.set('X-Plex-Token', token);
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain<void>();
      return response.statusCode < 500;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Adds [server]'s On Deck and recently added items, each with the time it
  /// sorts by and its id across servers.
  Future<void> _fetch(_Server server, List<_Found> watching, List<_Found> added) async {
    const page = 'X-Plex-Container-Start=0&X-Plex-Container-Size=20';
    final (deck, recent) = await (
      _send('GET', '${server.uri}/library/onDeck?$page', token: server.token),
      _send('GET', '${server.uri}/library/recentlyAdded?$page', token: server.token),
    ).wait;
    for (final (items, into, time) in [(deck, watching, 'lastViewedAt'), (recent, added, 'addedAt')]) {
      for (final m in _metadata(items)) {
        final item = _item(m, server);
        if (item == null) continue;
        final id = m['guid'] is String ? m['guid']! as String : '${server.id} ${m['ratingKey']}';
        into.add((m[time] is int ? m[time]! as int : 0, id, item));
      }
    }
  }

  static Iterable<Map<String, Object?>> _metadata(Object? reply) => switch (reply) {
    {'MediaContainer': {'Metadata': final List<Object?> items}} => items.whereType<Map<String, Object?>>(),
    _ => const [],
  };

  /// The name Plex gives an episode without a title of its own.
  static final _untitled = RegExp(r'^Episode \d+$');

  static ShowItem? _item(Map<String, Object?> m, _Server server) {
    String? text(String key) => m[key] is String && (m[key]! as String).isNotEmpty ? m[key]! as String : null;
    int? number(String key) => m[key] is int ? m[key]! as int : null;
    final key = text('ratingKey');
    if (key == null) return null;
    // An untitled episode Plex calls "Episode 3", which says no more than E3.
    final episode = switch (text('title')) {
      final title? when _untitled.hasMatch(title) => null,
      final title => title,
    };
    final (title, subtitle, picture) = switch (text('type')) {
      'episode' => (
        text('grandparentTitle') ?? text('title'),
        [
          [if (number('parentIndex') case final s?) 'S$s', if (number('index') case final e?) 'E$e'].join(' '),
          ?episode,
        ].where((part) => part.isNotEmpty).join(' · '),
        text('thumb') ?? text('grandparentArt'),
      ),
      'season' => (text('parentTitle') ?? text('title'), text('title'), text('art') ?? text('parentArt')),
      _ => (text('title'), number('year')?.toString(), text('art') ?? text('thumb')),
    };
    if (title == null) return null;
    final duration = number('duration');
    final offset = number('viewOffset');
    final started = duration != null && duration > 0 && offset != null && offset > 0;
    final address = 'server://${server.id}/com.plexapp.plugins.library/library/metadata/$key';
    return ShowItem(
      title: title,
      app: app,
      subtitle: subtitle,
      summary: text('summary'),
      image: picture == null
          ? null
          : '${server.uri}/photo/:/transcode?width=480&height=270&minSize=1&upscale=1'
                '&url=${Uri.encodeComponent(picture)}&X-Plex-Token=${server.token}',
      link: 'plex://watch/video?uri=${Uri.encodeComponent(address)}',
      progress: started ? offset / duration : null,
      minutesLeft: started ? ((duration - offset) / 60000).ceil() : null,
    );
  }

  /// One request to plex.tv or a server, as JSON. Plex knows GTVL by
  /// [_clientId]; [token] defaults to the account's.
  Future<Object?> _send(
    String method,
    String url, {
    String? token,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, Uri.parse(url));
      request.headers
        ..set('Accept', 'application/json')
        ..set('X-Plex-Product', 'GTVL')
        ..set('X-Plex-Device-Name', 'GTVL')
        ..set('X-Plex-Client-Identifier', _clientId);
      if (token ?? _token case final token?) request.headers.set('X-Plex-Token', token);
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode == HttpStatus.unauthorized && url.startsWith('https://plex.tv/')) {
        throw const _SignedOut();
      }
      if (response.statusCode >= 300) throw HttpException('Status ${response.statusCode}', uri: Uri.parse(url));
      return body.isEmpty ? null : jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}

/// plex.tv no longer takes the token: the user signed GTVL out elsewhere.
class _SignedOut implements Exception {
  const _SignedOut();
}
