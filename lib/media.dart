import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// What a gallery holds. Each kind has a folder in GTVL's git repository, with
/// a 480 x 270 JPEG preview of every file in its thumbs folder, named like
/// the file; downloads go to the same folder in the app's files.
enum MediaKind {
  pictures('Pictures', 'picture', 'wallpapers', 'image', ['.jpg', '.jpeg', '.png', '.webp']),
  videos('Videos', 'video', 'videos', 'video', ['.mp4', '.m4v', '.mov', '.mkv', '.webm']);

  const MediaKind(this.label, this._one, this.folder, this.wallpaper, this._extensions);

  final String label;
  final String _one;
  final String folder;

  /// Config.wallpaper's value while this kind shows.
  final String wallpaper;
  final List<String> _extensions;

  bool matches(String path) => _extensions.any(path.toLowerCase().endsWith);

  /// "1 video", "12 videos".
  String count(int n) => n == 1 ? '1 $_one' : '$n ${_one}s';
}

/// A file in GTVL's collection: its title, where to get it, its size in
/// bytes, and its preview.
typedef OnlineMedia = ({String name, String url, int size, String preview});

/// Pictures and videos for the wallpaper: from the TV's storage, or from
/// GTVL's collection online, downloaded when chosen.
abstract final class Media {
  /// The repository's folders, as GitHub lists them.
  static const _collection = 'https://api.github.com/repos/kanin-design/gtvl/contents';

  /// How long a connection may take to open, or a transfer go without a
  /// byte, before it counts as failed.
  static const _timeout = Duration(seconds: 15);

  /// The last part of [path].
  static String name(String path) => path.substring(path.lastIndexOf('/') + 1);

  /// [path]'s name without its extension.
  static String stem(String path) {
    final file = name(path);
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  /// "gold-ring.mp4" reads "Gold ring". A picture size last in the name is
  /// set apart: "fold-4k.mp4" reads "Fold · 4K".
  static String title(String path) {
    final words = stem(path).replaceAll(RegExp('[-_]+'), ' ').trim();
    if (words.isEmpty) return name(path);
    final title = words[0].toUpperCase() + words.substring(1);
    final size = _pictureSize.firstMatch(title);
    if (size == null) return title;
    final lines = size[2]!.toLowerCase();
    return '${size[1]} · ${lines.endsWith('k') ? lines.toUpperCase() : lines}';
  }

  static final _pictureSize = RegExp(r'^(.+) (\dk|\d{3,4}p)$', caseSensitive: false);

  /// The subfolders and files of [kind] in [path], each sorted by name. Hidden
  /// entries are left out, and so is Android's folder of app data, which other
  /// apps may not read.
  static Future<({List<String> folders, List<String> files})> list(String path, MediaKind kind) async {
    final folders = <String>[];
    final files = <String>[];
    try {
      await for (final entry in Directory(path).list()) {
        final entryName = name(entry.path);
        if (entryName.startsWith('.')) continue;
        if (entry is Directory) {
          if (entryName != 'Android') folders.add(entry.path);
        } else if (kind.matches(entryName)) {
          files.add(entry.path);
        }
      }
    } on FileSystemException {
      // Unreadable from here on: keep what was found.
    }
    int byName(String a, String b) => name(a).toLowerCase().compareTo(name(b).toLowerCase());
    return (folders: folders..sort(byName), files: files..sort(byName));
  }

  /// The files [sources] stand for: files of [kind] that are still there, and
  /// for each folder, every file of [kind] in it.
  static Future<List<String>> expand(List<String> sources, MediaKind kind) async => [
    for (final source in sources)
      if (!kind.matches(source)) ...(await list(source, kind)).files else if (await File(source).exists()) source,
  ];

  /// The collection's files of [kind]; null when it cannot be reached.
  static Future<List<OnlineMedia>?> online(MediaKind kind) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final response = await (await client.getUrl(Uri.parse('$_collection/${kind.folder}'))).close().timeout(_timeout);
      if (response.statusCode != 200) return null;
      final entries = jsonDecode(await response.transform(utf8.decoder).join().timeout(_timeout));
      return [
        if (entries is List)
          for (final entry in entries)
            if (entry case {
              'name': final String file,
              'download_url': final String url,
              'size': final int size,
            } when kind.matches(file))
              (
                name: title(file),
                url: url,
                size: size,
                preview: '${url.substring(0, url.lastIndexOf('/'))}/thumbs/${Uri.encodeComponent(stem(file))}.jpg',
              ),
      ];
    } on Exception {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Where the collection's file at [url] is kept in [dir] once downloaded.
  static String saved(String url, String dir, MediaKind kind) =>
      '$dir/${kind.folder}/${Uri.parse(url).pathSegments.last}';

  /// Downloads the collection's file at [url] into [dir], unless it is there
  /// already, and returns its path. [onProgress] hears how much is done, 0 to 1.
  /// Throws [DownloadStopped] once [stop] says so, and leaves nothing behind.
  static Future<String> download(
    String url,
    String dir,
    MediaKind kind, {
    void Function(double done)? onProgress,
    bool Function()? stop,
  }) async {
    final file = File(saved(url, dir, kind));
    if (await file.exists()) return file.path;
    // Written beside it first, so a broken download never looks finished.
    final part = File('${file.path}.part');
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close().timeout(_timeout);
      if (response.statusCode != 200) throw HttpException('Status ${response.statusCode}', uri: Uri.parse(url));
      await file.parent.create(recursive: true);
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(_timeout)) {
          if (stop?.call() ?? false) throw const DownloadStopped();
          sink.add(chunk);
          received += chunk.length;
          if (response.contentLength > 0) onProgress?.call(received / response.contentLength);
        }
      } finally {
        await sink.close();
      }
      await part.rename(file.path);
      return file.path;
    } catch (_) {
      if (await part.exists()) await part.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// The collection's files of [kind] kept in [dir] once downloaded, each
  /// with its size in bytes.
  static Future<Map<String, int>> kept(String dir, MediaKind kind) async {
    final kept = <String, int>{};
    for (final file in (await list('$dir/${kind.folder}', kind)).files) {
      try {
        kept[file] = await File(file).length();
      } on FileSystemException {
        // Gone since it was listed.
      }
    }
    return kept;
  }

  /// Deletes a downloaded file; it comes again if chosen again.
  static Future<void> forget(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Deletes every downloaded file of [kind] in [dir], and any download left
  /// half done, but for [except].
  static Future<void> forgetAll(String dir, MediaKind kind, {Set<String> except = const {}}) async {
    try {
      for (final entry in await Directory('$dir/${kind.folder}').list().toList()) {
        if (entry is File && !except.contains(entry.path)) await forget(entry.path);
      }
    } on FileSystemException {
      // Nothing was ever downloaded.
    }
  }
}

/// Downloads from the collection under way. They outlive settings, so one
/// still coming in shows as that when settings opens again, and never starts
/// a second time.
class Downloads extends ChangeNotifier {
  /// Each download's url, with how much of it is done, 0 to 1.
  final progress = <String, double>{};

  /// Those the user stopped, until they end, and those that failed.
  final stopping = <String>{};
  final failed = <String>{};

  /// Videos this TV turned out not to play, by url: known only once one is
  /// here, so remembered while GTVL runs, not to come again for nothing.
  final unplayable = <String>{};

  /// Stops the download of [url] as its next piece arrives, or the wait for
  /// that runs out.
  void stop(String url) {
    if (progress.containsKey(url) && stopping.add(url)) notifyListeners();
  }

  /// Downloads the collection's file at [url] into [dir] and returns its
  /// path; null when it was stopped or failed, or is coming in already.
  Future<String?> fetch(String url, String dir, MediaKind kind) async {
    if (progress.containsKey(url)) return null;
    progress[url] = 0;
    failed.remove(url);
    notifyListeners();
    try {
      final path = await Media.download(
        url,
        dir,
        kind,
        stop: () => stopping.contains(url),
        onProgress: (done) {
          // A step per percent, not one per chunk.
          if ((done * 100).floor() > (progress[url]! * 100).floor()) {
            progress[url] = done;
            notifyListeners();
          }
        },
      );
      // Stopped as the last piece came in: the file stays, but isn't chosen.
      return stopping.contains(url) ? null : path;
    } on DownloadStopped {
      return null;
    } on Exception {
      failed.add(url);
      return null;
    } finally {
      progress.remove(url);
      stopping.remove(url);
      notifyListeners();
    }
  }
}

/// A download stopped on request, before it was done.
class DownloadStopped implements Exception {
  const DownloadStopped();
}
