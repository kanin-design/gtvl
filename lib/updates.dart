import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'config.dart';
import 'native.dart';

/// A newer GTVL: its version, and the APK for this TV's kind of processor.
typedef Release = ({String version, int build, Uri apk, int size, String sha256, String? notes});

/// Where an update stands.
enum UpdateState { idle, checking, latest, downloading, ready, installing, failed }

/// New versions of GTVL, from the releases of its GitHub repository.
///
/// Each release carries gtvl-update.json (written by tool/build.sh): the
/// version, and for each kind of processor (ABI) the APK's file name, size,
/// SHA-256 and Android version code. GTVL reads the latest release's file,
/// downloads the APK for this TV over HTTPS from GitHub only, and has
/// Android's side check it: the size and SHA-256, that it is GTVL, newer
/// than this copy, and signed with the same key. Only then may it install,
/// and Android checks the key once more as it does. A release reaches TVs
/// once it is published; drafts and pre-releases don't.
///
/// With [Config.autoUpdate] on, this happens every few hours by itself. Where
/// Android lets GTVL update itself without asking (Android 12 on, once the
/// user has let GTVL install apps), the update then installs as the TV goes
/// to standby; elsewhere it waits in About.
class Updates extends ChangeNotifier {
  Updates(this._config, this._cache);

  final Config _config;
  final String _cache;

  static const _repo = 'kanin-design/gtvl';
  static final _latest = Uri.https('github.com', '/$_repo/releases/latest/download/gtvl-update.json');
  static const _every = Duration(hours: 6);
  static const _timeout = Duration(seconds: 30);

  UpdateState state = UpdateState.idle;

  /// The newer version found, if any.
  Release? release;

  /// How much of the download is done, 0 to 1.
  double progress = 0;

  /// Why the last try failed, for the user.
  String? problem;

  /// This copy's version name, e.g. "0.2.2".
  String version = '';

  /// Android lets GTVL install apps (the user's switch), and could let it
  /// update itself without asking (Android 12 on), which takes that switch too.
  bool allowed = false, quiet = false;

  int _build = 0, _room = 0;
  List<String> _abis = const [];

  /// The checked download, ready to install.
  String? _apk;

  /// An update at standby turned out to need the user: it waits for them.
  bool _ask = false;

  /// Install was chosen before the user's switch was on. The first return to
  /// GTVL settles it: the install goes ahead if the switch is on by then, and
  /// is dropped if not, so it can't start by itself days later.
  bool _installWhenAllowed = false;

  /// Version codes whose download failed its checks: not fetched again until
  /// GTVL restarts, so a bad release doesn't download every few hours.
  final _rejected = <int>{};
  DateTime? _checked;
  Timer? _timer, _settle;
  AppLifecycleListener? _lifecycle;

  /// Checking or downloading: nothing more to start.
  bool get busy => state == UpdateState.checking || state == UpdateState.downloading || state == UpdateState.installing;

  /// An update is ready and waits for the user, rather than installing by itself at standby.
  bool get waiting => state == UpdateState.ready && (_ask || !_config.autoUpdate || !quiet || !allowed);

  Future<void> start() async {
    Native.events.where((event) => event['type'] == 'update').listen(_onInstaller);
    _lifecycle = AppLifecycleListener(onResume: _resumed);
    await _refresh();
    await _clean();
    // Every so often; a check happens once it's been long enough.
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => _auto());
    // Not during start-up's own work.
    Timer(const Duration(minutes: 1), _auto);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _settle?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Back in GTVL: whether it may install now (after Android's switch), going
  /// ahead with an install chosen before it was on (or dropping it), and an
  /// install whose confirmation was left unanswered (Home) is ready again.
  /// One confirmed ends GTVL's process well before the wait is up.
  Future<void> _resumed() async {
    _settle?.cancel();
    if (state == UpdateState.installing) {
      _settle = Timer(const Duration(seconds: 10), () {
        if (state == UpdateState.installing) _set(UpdateState.ready);
      });
    }
    await _refresh();
    _offer();
    final goAhead = _installWhenAllowed && allowed;
    _installWhenAllowed = false;
    if (goAhead) await install();
  }

  void setAuto(bool on) {
    _config.autoUpdate = on;
    _config.changed();
    _offer();
    if (on) _auto();
    notifyListeners();
  }

  Future<void> _auto() async {
    if (!_config.autoUpdate || busy || state == UpdateState.ready) return;
    if (_checked case final checked? when DateTime.now().difference(checked) < _every) return;
    await check();
  }

  /// Looks for a newer release and, when there is one, downloads and checks it.
  Future<void> check() async {
    if (busy) return;
    _set(UpdateState.checking);
    try {
      await _refresh();
      final found = await _find();
      _checked = DateTime.now();
      release = found;
      if (found == null) {
        _set(UpdateState.latest);
        return;
      }
      if (_rejected.contains(found.build)) {
        throw _Problem("Version ${found.version} failed GTVL's checks, so it won't be installed.");
      }
      await _download(found);
    } on Object catch (e) {
      // Anything at all, so a check never stays busy.
      debugPrint('Update: $e');
      problem = _why(e);
      _set(UpdateState.failed);
    }
  }

  /// Installs the update that is ready. GTVL first needs the user's leave to
  /// install apps: they turn the switch on and come back, and the install
  /// goes ahead. Android 12 and later want that switch too, even for an app
  /// updating itself; with it, they install without asking.
  Future<void> install() async {
    final apk = _apk;
    if (apk == null || state != UpdateState.ready) return;
    _installWhenAllowed = false;
    await _refresh();
    // A second press while that was asked finds the first already installing.
    if (state != UpdateState.ready) return;
    if (!allowed) {
      _installWhenAllowed = true;
      // No settings page opened, so GTVL won't be left and come back.
      if (!await Native.allowUpdates()) _installWhenAllowed = false;
      return;
    }
    _set(UpdateState.installing);
    try {
      await Native.installUpdate(apk);
    } on PlatformException catch (e) {
      problem = "Android couldn't install the update (${e.message}).";
      _set(UpdateState.failed);
    }
  }

  void _onInstaller(Map<Object?, Object?> event) {
    switch (event['what']) {
      // Android asks the user now, or the update is in and GTVL restarts.
      case 'confirm' || 'installed':
        _set(UpdateState.installing);
      case 'cancelled':
        _set(UpdateState.ready);
      case 'waiting':
        _ask = true;
        _offer();
        _set(UpdateState.ready);
      default:
        final message = event['message'];
        problem = message is String && message.isNotEmpty
            ? "Android couldn't install the update ($message)."
            : "Android couldn't install the update.";
        _set(UpdateState.failed);
    }
  }

  /// Has the ready update install at the next standby, if that needs no one.
  void _offer() {
    final quietly = state == UpdateState.ready && _config.autoUpdate && quiet && allowed && !_ask;
    Native.updateAtStandby(quietly ? _apk : null);
  }

  Future<void> _refresh() async {
    final info = await Native.updateInfo();
    version = info.version;
    allowed = info.allowed;
    quiet = info.quiet;
    _build = info.build;
    _abis = info.abis;
    _room = info.room;
    notifyListeners();
  }

  /// The latest release, if newer than this copy; throws if it can't be read.
  Future<Release?> _find() async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final response = await _open(client, _latest);
      // No release has an update file yet.
      if (response.statusCode == HttpStatus.notFound) {
        await response.drain<void>();
        return null;
      }
      if (response.statusCode != HttpStatus.ok) throw HttpException('Status ${response.statusCode}', uri: _latest);
      final bytes = <int>[];
      await for (final chunk in response.timeout(_timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > 64 * 1024) throw const _Problem('The update details on GitHub are too big to read.');
      }
      final found = _parse(jsonDecode(utf8.decode(bytes)));
      return found.build > _build ? found : null;
    } finally {
      client.close(force: true);
    }
  }

  static final _tag = RegExp(r'^v[0-9A-Za-z.\-]+$');
  static final _file = RegExp(r'^gtvl-[0-9A-Za-z.\-]+\.apk$');
  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  /// [json] as the release for this TV. Its APK can only come from this
  /// repository's releases: the address is built here, never taken from the file.
  Release _parse(Object? json) {
    if (json case final Map<String, Object?> data) {
      if (data case {
        'schema': 1,
        'app': 'kanin.gtvl',
        'version': final String version,
        'tag': final String tag,
        'files': final Map<String, Object?> files,
      } when _tag.hasMatch(tag)) {
        return _forThisTv(version, tag, files, data['notes']);
      }
    }
    throw const _Problem("The update details on GitHub can't be read.");
  }

  /// The first of this TV's processor kinds, in Android's order of
  /// preference, that the release has an APK for.
  Release _forThisTv(String version, String tag, Map<String, Object?> files, Object? notes) {
    for (final abi in _abis) {
      if (files[abi] case {
        'name': final String name,
        'size': final int size,
        'sha256': final String sha256,
        'versionCode': final int build,
      } when _file.hasMatch(name) && _hash.hasMatch(sha256) && size > 0 && size < 200 << 20) {
        return (
          version: version,
          build: build,
          apk: Uri.https('github.com', '/$_repo/releases/download/$tag/$name'),
          size: size,
          sha256: sha256,
          notes: notes is String && notes.isNotEmpty ? notes : null,
        );
      }
    }
    throw const _Problem('The latest version has no download for this TV.');
  }

  /// Downloads [found] unless it's here already, then has Android's side check it.
  Future<void> _download(Release found) async {
    final file = File('$_cache/updates/gtvl-${found.build}.apk');
    if (!await file.exists() || await file.length() != found.size) {
      // The download, the installer's copy, and room to spare.
      if (_room < found.size * 3) throw const _Problem('Not enough free space on the TV for the update.');
      progress = 0;
      _set(UpdateState.downloading);
      await _fetch(found, file);
    }
    final rejected = await Native.checkUpdate(file.path, size: found.size, sha256: found.sha256);
    if (rejected != null) {
      await _delete(file);
      // A damaged download may come right next time; anything else won't.
      if (rejected != 'size' && rejected != 'checksum') _rejected.add(found.build);
      throw _Problem(_rejections[rejected] ?? 'The download failed its checks.');
    }
    _apk = file.path;
    _ask = false;
    _set(UpdateState.ready);
    _offer();
  }

  static const _rejections = {
    'size': 'The download was damaged. Try again.',
    'checksum': 'The download was damaged. Try again.',
    'unreadable': "The download isn't an app Android can read.",
    'package': "The download isn't GTVL.",
    'older': 'This version is already installed.',
    'android': 'This version needs a newer Android.',
    'signer': "The download isn't signed with GTVL's key, so it won't be installed.",
  };

  /// Writes [found]'s APK beside [file] first, so a broken download never looks finished.
  Future<void> _fetch(Release found, File file) async {
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final response = await _open(client, found.apk);
      if (response.statusCode != HttpStatus.ok) throw HttpException('Status ${response.statusCode}', uri: found.apk);
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(_timeout)) {
          received += chunk.length;
          if (received > found.size) throw const _Problem('The download was bigger than expected.');
          sink.add(chunk);
          // Each whole per cent, not each chunk.
          final done = received / found.size;
          if ((done * 100).floor() != (progress * 100).floor()) {
            progress = done;
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      await part.rename(file.path);
    } catch (_) {
      await _delete(part);
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// GETs [url], following redirects only over HTTPS and only to GitHub's
  /// own hosts (release files are served from githubusercontent.com).
  static Future<HttpClientResponse> _open(HttpClient client, Uri url) async {
    for (var hops = 0; hops < 5; hops++) {
      if (url.scheme != 'https' || !(url.host == 'github.com' || url.host.endsWith('.githubusercontent.com'))) {
        throw _Problem('An update may only come from GitHub, not ${url.host}.');
      }
      final request = await client.getUrl(url).timeout(_timeout);
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.userAgentHeader, 'GTVL');
      final response = await request.close().timeout(_timeout);
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null) throw HttpException('Redirect without a location', uri: url);
      url = url.resolve(location);
    }
    throw HttpException('Too many redirects', uri: url);
  }

  /// Downloads from before: installed by now, or broken off.
  Future<void> _clean() async {
    final dir = Directory('$_cache/updates');
    if (!await dir.exists()) return;
    await for (final entry in dir.list()) {
      final name = entry.uri.pathSegments.last;
      final build = int.tryParse(RegExp(r'^gtvl-(\d+)\.apk$').firstMatch(name)?.group(1) ?? '');
      if (build == null || build <= _build) await _delete(entry);
    }
  }

  static Future<void> _delete(FileSystemEntity entry) async {
    try {
      await entry.delete();
    } on FileSystemException {
      // Gone already.
    }
  }

  static String _why(Object e) => switch (e) {
    _Problem(:final text) => text,
    SocketException() || TimeoutException() || HandshakeException() => "Couldn't reach GitHub.",
    HttpException() => "GitHub didn't answer as expected.",
    FormatException() => "The update details on GitHub can't be read.",
    FileSystemException() => "Couldn't save the download.",
    _ => 'Something went wrong.',
  };

  void _set(UpdateState next) {
    state = next;
    if (next != UpdateState.failed) problem = null;
    notifyListeners();
  }
}

/// Why an update stopped, in words for the user.
class _Problem implements Exception {
  const _Problem(this.text);

  final String text;

  @override
  String toString() => text;
}
