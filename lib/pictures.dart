import 'dart:convert';
import 'dart:io';

/// Pictures for the wallpaper: from the TV's storage (one picture, or a
/// folder of them shown in turn), or from the wallpapers folder of GTVL's git
/// repository, downloaded when chosen.
abstract final class Pictures {
  /// The repository's wallpapers folder, as GitHub lists it.
  static const _collection = 'https://api.github.com/repos/kanin-design/gtvl/contents/wallpapers';

  static bool isPicture(String path) => const ['.jpg', '.jpeg', '.png', '.webp'].any(path.toLowerCase().endsWith);

  /// The last part of [path].
  static String name(String path) => path.substring(path.lastIndexOf('/') + 1);

  /// The subfolders and pictures in [path], each sorted by name. Hidden
  /// entries are left out, and so is Android's folder of app data, which other
  /// apps may not read.
  static Future<({List<String> folders, List<String> pictures})> list(String path) async {
    final folders = <String>[];
    final pictures = <String>[];
    try {
      await for (final entry in Directory(path).list()) {
        final entryName = name(entry.path);
        if (entryName.startsWith('.')) continue;
        if (entry is Directory) {
          if (entryName != 'Android') folders.add(entry.path);
        } else if (isPicture(entryName)) {
          pictures.add(entry.path);
        }
      }
    } on FileSystemException {
      // Unreadable from here on: keep what was found.
    }
    int byName(String a, String b) => name(a).toLowerCase().compareTo(name(b).toLowerCase());
    return (folders: folders..sort(byName), pictures: pictures..sort(byName));
  }

  /// The wallpapers in the repository, as (name, url); empty when it cannot
  /// be reached.
  static Future<List<({String name, String url})>> online() async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(_collection))).close();
      if (response.statusCode != 200) return const [];
      final entries = jsonDecode(await response.transform(utf8.decoder).join());
      return [
        if (entries is List)
          for (final entry in entries)
            if (entry case {'name': final String file, 'download_url': final String url} when isPicture(file))
              (name: _title(file), url: url),
      ];
    } on Exception {
      return const [];
    } finally {
      client.close();
    }
  }

  /// Where the wallpaper at [url] is kept in [dir] once downloaded.
  static String saved(String url, String dir) => '$dir/wallpapers/${Uri.parse(url).pathSegments.last}';

  /// Downloads the wallpaper at [url] into [dir], unless it is there already,
  /// and returns its path.
  static Future<String> download(String url, String dir) async {
    final file = File(saved(url, dir));
    if (await file.exists()) return file.path;
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) throw HttpException('Status ${response.statusCode}', uri: Uri.parse(url));
      await file.parent.create(recursive: true);
      // Written beside it first, so a broken download never looks finished.
      final part = File('${file.path}.part');
      await response.pipe(part.openWrite());
      await part.rename(file.path);
      return file.path;
    } finally {
      client.close();
    }
  }

  /// "purple-abstract.jpg" reads "Purple abstract".
  static String _title(String file) {
    final words = file.substring(0, file.lastIndexOf('.')).replaceAll(RegExp('[-_]+'), ' ').trim();
    return words.isEmpty ? file : words[0].toUpperCase() + words.substring(1);
  }
}
