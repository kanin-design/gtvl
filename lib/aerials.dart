import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One video for the wallpaper player.
class Scene {
  const Scene(this.uri, this.caption, {this.file = false, this.loop = false});

  final String uri;

  /// e.g. "Hawaii · Pu'u O 'Umi".
  final String caption;

  /// [uri] is a path on the device.
  final bool file;

  /// Play this scene forever instead of moving on.
  final bool loop;
}

/// Apple TV aerial films: a bundled list played in shuffled order, none
/// repeating before all have played, with one film kept on disk so the
/// wallpaper starts instantly.
class Aerials {
  Aerials(this._dir);

  final String _dir;
  final _random = Random();
  final _bag = <Map<String, Object?>>[];
  List<Map<String, Object?>> _all = const [];
  HttpClient? _http;
  bool _saving = false;

  static const qualities = ['1080p', '1080p_hdr', '4k', '4k_hdr'];

  /// A film is hundreds of megabytes: the cache follows what plays, but at
  /// most this often, so it never doubles the traffic.
  static const _refreshAfter = Duration(hours: 12);

  File get _video => File('$_dir/aerial.mov');
  File get _meta => File('$_dir/aerial.json');

  Future<void> load() async {
    final json = jsonDecode(await rootBundle.loadString('assets/aerials.json')) as Map<String, Object?>;
    _all = [for (final video in json['videos']! as List) video as Map<String, Object?>];
  }

  /// The film to play after [previous]: the saved one when starting, then a
  /// shuffled one that is never the same twice in a row.
  Scene? next(Scene? previous, String quality) {
    if (previous == null) {
      final saved = _saved(quality);
      if (saved != null) return saved;
    }
    if (_all.isEmpty) return null;
    if (_bag.isEmpty) {
      _bag.addAll(List.of(_all)..shuffle(_random));
      if (_bag.length > 1 && _caption(_bag.last) == previous?.caption) _bag.insert(0, _bag.removeLast());
    }
    final video = _bag.removeLast();
    final url = (video['url_$quality'] ?? video['url_1080p']) as String?;
    return url == null ? null : Scene(url, _caption(video));
  }

  static String _caption(Map<String, Object?> video) =>
      [video['location'], video['title']].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

  Scene? _saved(String quality) {
    try {
      final meta = jsonDecode(_meta.readAsStringSync()) as Map<String, Object?>;
      if (meta['quality'] != quality || !_video.existsSync()) return null;
      return Scene(_video.path, meta['caption'] as String? ?? '', file: true);
    } on Object {
      return null; // nothing saved yet
    }
  }

  /// Saves [scene] to disk for the next start, unless the saved film is recent.
  Future<void> remember(Scene scene, String quality) async {
    if (_saving || scene.file) return;
    if (_saved(quality) != null && DateTime.now().difference(_meta.lastModifiedSync()) < _refreshAfter) return;
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
      await _meta.writeAsString(jsonEncode({'caption': scene.caption, 'quality': quality}));
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
