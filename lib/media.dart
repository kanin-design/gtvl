import 'dart:convert';
import 'dart:io';

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

/// A file in GTVL's collection: its title, where to get it, and its preview.
typedef OnlineMedia = ({String name, String url, String preview});

/// Pictures and videos for the wallpaper: from the TV's storage, or from
/// GTVL's collection online, downloaded when chosen.
abstract final class Media {
  /// The repository's folders, as GitHub lists them.
  static const _collection = 'https://api.github.com/repos/kanin-design/gtvl/contents';

  /// The last part of [path].
  static String name(String path) => path.substring(path.lastIndexOf('/') + 1);

  /// [path]'s name without its extension.
  static String stem(String path) {
    final file = name(path);
    final dot = file.lastIndexOf('.');
    return dot > 0 ? file.substring(0, dot) : file;
  }

  /// "arc-fold.mp4" reads "Arc fold".
  static String title(String path) {
    final words = stem(path).replaceAll(RegExp('[-_]+'), ' ').trim();
    return words.isEmpty ? name(path) : words[0].toUpperCase() + words.substring(1);
  }

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

  /// The collection's files of [kind]; empty when it cannot be reached.
  static Future<List<OnlineMedia>> online(MediaKind kind) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse('$_collection/${kind.folder}'))).close();
      if (response.statusCode != 200) return const [];
      final entries = jsonDecode(await response.transform(utf8.decoder).join());
      return [
        if (entries is List)
          for (final entry in entries)
            if (entry case {'name': final String file, 'download_url': final String url} when kind.matches(file))
              (
                name: title(file),
                url: url,
                preview: '${url.substring(0, url.lastIndexOf('/'))}/thumbs/${Uri.encodeComponent(stem(file))}.jpg',
              ),
      ];
    } on Exception {
      return const [];
    } finally {
      client.close();
    }
  }

  /// Where the collection's file at [url] is kept in [dir] once downloaded.
  static String saved(String url, String dir, MediaKind kind) =>
      '$dir/${kind.folder}/${Uri.parse(url).pathSegments.last}';

  /// Downloads the collection's file at [url] into [dir], unless it is there
  /// already, and returns its path. [onProgress] hears how much is done, 0 to 1.
  static Future<String> download(
    String url,
    String dir,
    MediaKind kind, {
    void Function(double done)? onProgress,
  }) async {
    final file = File(saved(url, dir, kind));
    if (await file.exists()) return file.path;
    // Written beside it first, so a broken download never looks finished.
    final part = File('${file.path}.part');
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) throw HttpException('Status ${response.statusCode}', uri: Uri.parse(url));
      await file.parent.create(recursive: true);
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
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
      client.close();
    }
  }

  /// Deletes a downloaded file; it comes again if chosen again.
  static Future<void> forget(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
