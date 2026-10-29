import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One video for the wallpaper player.
class Scene {
  const Scene(this.uri, this.caption, {this.kind = '', this.file = false, this.loop = false, this.hdr = false});

  final String uri;

  /// For aerials, one of [Aerials.kinds].
  final String kind;

  /// e.g. "Hawaii · Pu'u O 'Umi".
  final String caption;

  /// [uri] is a path on the device.
  final bool file;

  /// Play this scene forever instead of moving on.
  final bool loop;

  /// Dolby Vision, which shows only on the TV's own video surface.
  final bool hdr;
}

/// Apple TV aerial films: a bundled list played in shuffled order, none
/// repeating before all have played, with one film kept on disk so the
/// wallpaper starts instantly.
class Aerials {
  Aerials(this._dir, {this.hdr = const {}});

  /// The HDR qualities this TV can show, asked of it at start; any other HDR
  /// choice plays its SDR twin.
  final Set<String> hdr;

  final String _dir;
  final _random = Random();
  final _bag = <Map<String, Object?>>[];
  List<Map<String, Object?>> _all = const [];
  HttpClient? _http;
  bool _saving = false;

  /// Scene kinds the user can turn off: from the space station, under the
  /// sea, over cities, and over landscapes.
  static const kinds = ['space', 'underwater', 'cities', 'landscapes'];
  static const _cities = {'Dubai', 'Los Angeles', 'Hong Kong', 'San Francisco', 'London', 'New York City'};

  /// The bag holds one selection of kinds; a new selection starts a new bag.
  String _bagKinds = '';

  /// A film is hundreds of megabytes: the cache follows what plays, but at
  /// most this often, so it never doubles the traffic.
  static const _refreshAfter = Duration(hours: 12);

  File get _video => File('$_dir/aerial.mov');
  File get _meta => File('$_dir/aerial.json');

  Future<void> load() async {
    final json = jsonDecode(await rootBundle.loadString('assets/aerials.json')) as Map<String, Object?>;
    _all = [for (final video in json['videos']! as List) video as Map<String, Object?>];
  }

  /// How many films there are of [kind].
  int count(String kind) => _all.where((video) => _kind(video) == kind).length;

  /// The film to play after [previous]: the saved one when starting (if
  /// [useSaved]), then a shuffled one that is never the same twice in a row.
  /// Kinds in [off] are skipped, unless that would leave nothing.
  Scene? next(Scene? previous, String quality, {Set<String> off = const {}, bool useSaved = true}) {
    quality = _playable(quality);
    if (previous == null && useSaved) {
      final saved = _saved(quality, off);
      if (saved != null) return saved;
    }
    final allowed = _all.where((video) => !off.contains(_kind(video))).toList();
    final films = allowed.isEmpty ? _all : allowed;
    if (films.isEmpty) return null;
    final selection = (off.toList()..sort()).join(',');
    if (selection != _bagKinds) {
      _bag.clear();
      _bagKinds = selection;
    }
    if (_bag.isEmpty) {
      _bag.addAll(List.of(films)..shuffle(_random));
      if (_bag.length > 1 && _caption(_bag.last) == previous?.caption) _bag.insert(0, _bag.removeLast());
    }
    final video = _bag.removeLast();
    final url = (video['url_$quality'] ?? video['url_1080p']) as String?;
    return url == null ? null : Scene(url, _caption(video), kind: _kind(video), hdr: quality.endsWith('_hdr'));
  }

  /// [quality], or its SDR twin when this TV can't show it.
  String _playable(String quality) =>
      quality.endsWith('_hdr') && !hdr.contains(quality) ? quality.replaceFirst('_hdr', '') : quality;

  static String _caption(Map<String, Object?> video) =>
      [video['location'], video['title']].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  static String _kind(Map<String, Object?> video) => switch (video['location']) {
    'ISS' => 'space',
    'Undersea' => 'underwater',
    final String place when _cities.contains(place) => 'cities',
    _ => 'landscapes',
  };

  Scene? _saved(String quality, Set<String> off) {
    try {
      final meta = jsonDecode(_meta.readAsStringSync()) as Map<String, Object?>;
      final kind = meta['kind'] as String? ?? '';
      if (meta['quality'] != quality || off.contains(kind) || !_video.existsSync()) return null;
      return Scene(
        _video.path,
        meta['caption'] as String? ?? '',
        kind: kind,
        file: true,
        hdr: quality.endsWith('_hdr'),
      );
    } on Object {
      return null; // nothing saved yet
    }
  }

  /// Deletes the saved film, for when instant start is turned off.
  Future<void> forget() async {
    for (final file in [_meta, _video]) {
      if (await file.exists()) await file.delete();
    }
  }

  /// Saves [scene] to disk for the next start, unless the saved film is recent.
  Future<void> remember(Scene scene, String quality) async {
    if (_saving || scene.file) return;
    quality = _playable(quality);
    if (_saved(quality, const {}) != null && DateTime.now().difference(_meta.lastModifiedSync()) < _refreshAfter) {
      return;
    }
    _saving = true;
    final part = File('$_dir/aerial.part');
    try {
      await Directory(_dir).create(recursive: true);
      final response = await (await (_http ??= await _client()).getUrl(Uri.parse(scene.uri))).close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return;
      }
      await response.pipe(part.openWrite());
      // Drop the old caption first, so a crash never pairs it with the new film.
      if (await _meta.exists()) await _meta.delete();
      await part.rename(_video.path);
      await _meta.writeAsString(jsonEncode({'caption': scene.caption, 'kind': scene.kind, 'quality': quality}));
    } on Object catch (e) {
      debugPrint('Could not save aerial: $e');
    } finally {
      if (await part.exists()) await part.delete();
      _saving = false;
    }
  }

  /// Also trusts Apple's own root: it signs the aerial host but is not in
  /// Android's certificate store.
  static Future<HttpClient> _client() async {
    final root = await rootBundle.load('assets/apple_root_ca.pem');
    return HttpClient(
      context: SecurityContext(withTrustedRoots: true)..setTrustedCertificatesBytes(root.buffer.asUint8List()),
    );
  }
}
