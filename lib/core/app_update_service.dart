import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'package:path_provider/path_provider.dart';

import 'app_update_release.dart';

class UpdateCancellation {
  bool cancelled = false;
  String _reason = 'cancelled';
  final _callbacks = <void Function()>[];
  void cancel({String reason = 'cancelled'}) {
    if (cancelled) return;
    cancelled = true;
    _reason = reason;
    for (final callback in List.of(_callbacks)) {
      callback();
    }
    _callbacks.clear();
  }

  void check() {
    if (cancelled) throw UpdateFailure(_reason);
  }

  void add(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void remove(void Function() callback) => _callbacks.remove(callback);
}

abstract interface class UpdateTransport {
  Stream<List<int>> read(Uri url, UpdateCancellation token);
}

/// Never sends site cookies, model keys or a GitHub token. Only official HTTPS
/// endpoints and GitHub's signed release-asset redirects are accepted.
class GithubUpdateTransport implements UpdateTransport {
  GithubUpdateTransport({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;
  final HttpClient Function() _clientFactory;
  static bool trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      !uri.hasFragment &&
      const {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  @override
  Stream<List<int>> read(Uri url, UpdateCancellation token) async* {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 15)
      ..autoUncompress = false;
    void abort() => client.close(force: true);
    token.add(abort);
    try {
      var current = url;
      for (var redirects = 0; redirects <= 5; redirects++) {
        token.check();
        if (!trusted(current)) throw const UpdateFailure('untrusted');
        final request = await client
            .getUrl(current)
            .timeout(const Duration(seconds: 15));
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Tsukuyomi-Space-App-Updater',
        );
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set(
          HttpHeaders.acceptHeader,
          current.host == 'api.github.com'
              ? 'application/vnd.github+json'
              : 'application/octet-stream',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        token.check();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null) throw const UpdateFailure('untrusted');
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw UpdateFailure(
            response.statusCode == 403 || response.statusCode == 429
                ? 'rateLimit'
                : 'network',
          );
        }
        await for (final bytes in response.timeout(
          const Duration(seconds: 30),
        )) {
          token.check();
          yield bytes;
        }
        token.check();
        return;
      }
      throw const UpdateFailure('untrusted');
    } on UpdateFailure {
      rethrow;
    } catch (_) {
      token.check();
      throw const UpdateFailure('network');
    } finally {
      token.remove(abort);
      client.close(force: true);
    }
  }
}

Future<String> updateFileHash(String path) => Isolate.run(
  () async => (await sha256.bind(File(path).openRead()).first).toString(),
);

class AppUpdateService {
  AppUpdateService({
    UpdateTransport? transport,
    Future<Directory> Function()? cacheDirectory,
  }) : transport = transport ?? GithubUpdateTransport(),
       cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory;
  final UpdateTransport transport;
  final Future<Directory> Function() cacheDirectory;

  Future<void> _prune(Directory root, String keep) async {
    // Only this updater's old installer cache; never recurse or follow links.
    final known = RegExp(
      r'^tsukuyomi-space-\d+\.\d+\.\d+-(?:windows-x64-setup\.exe|macos-universal\.dmg|linux-x64\.deb|android-(?:arm64-v8a|x86_64)\.apk|ios-arm64-unsigned\.ipa)(?:\.part)?$',
    );
    try {
      await for (final entry in root.list(followLinks: false).take(64)) {
        final name = entry.uri.pathSegments.last;
        if (entry is! File || name == keep || !known.hasMatch(name)) continue;
        if (DateTime.now().difference(await entry.lastModified()) >
            const Duration(days: 7)) {
          await entry.delete();
        }
      }
    } catch (_) {
      /* Cache maintenance must not prevent an update. */
    }
  }

  Future<String> _text(Uri uri, int limit, UpdateCancellation token) async {
    final builder = BytesBuilder(copy: false);
    await for (final bytes in transport.read(uri, token)) {
      if (builder.length + bytes.length > limit) {
        throw const UpdateFailure('metadata');
      }
      builder.add(bytes);
    }
    token.check();
    try {
      return utf8.decode(builder.takeBytes());
    } catch (_) {
      throw const UpdateFailure('metadata');
    }
  }

  Future<AppUpdateRelease?> check(
    AppVersion installed,
    UpdatePlatform platform, {
    required bool previews,
    required UpdateCancellation token,
  }) async {
    final source = await _text(appReleasesApi, 1024 * 1024, token).timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        token.cancel();
        throw const UpdateFailure('network');
      },
    );
    Object? catalog;
    try {
      catalog = jsonDecode(source);
    } catch (_) {
      throw const UpdateFailure('metadata');
    }
    return selectAppUpdate(catalog, installed, platform, previews: previews);
  }

  Future<File> download(
    AppUpdateRelease release,
    UpdateCancellation token,
    void Function(int received, int total, bool verifying) progress,
  ) async {
    final deadline = Timer(
      const Duration(minutes: 20),
      () => token.cancel(reason: 'network'),
    );
    try {
      return await _download(release, token, progress);
    } finally {
      deadline.cancel();
    }
  }

  Future<File> _download(
    AppUpdateRelease release,
    UpdateCancellation token,
    void Function(int received, int total, bool verifying) progress,
  ) async {
    final checksums = await _text(release.checksums.url, 65536, token).timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        token.cancel();
        throw const UpdateFailure('network');
      },
    );
    final hash = updateChecksum(checksums, release.installer);
    final root = Directory(
      paths.join((await cacheDirectory()).path, 'tsukuyomi-updates'),
    );
    token.check();
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const UpdateFailure('storage');
    }
    await root.create(recursive: true);
    await _prune(root, release.installer.name);
    final installer = File(paths.join(root.path, release.installer.name));
    final partial = File('${installer.path}.part');
    IOSink? sink;
    try {
      for (final file in [installer, partial]) {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const UpdateFailure('storage');
        }
      }
      // A completed previous download can be reused after a fresh checksum test.
      if (await installer.exists()) {
        progress(0, release.installer.size, true);
        if (await installer.length() == release.installer.size &&
            await updateFileHash(installer.path) == hash) {
          token.check();
          return installer;
        }
        await installer.delete();
      }
      token.check();
      sink = partial.openWrite(mode: FileMode.writeOnly);
      // Observe sink errors immediately, even if they occur between HTTP chunks.
      Object? writeError;
      final done = sink.done.then<void>(
        (_) {},
        onError: (Object error) {
          writeError = error;
        },
      );
      var received = 0;
      var buffered = 0;
      progress(0, release.installer.size, false);
      await for (final bytes in transport.read(release.installer.url, token)) {
        token.check();
        if (writeError != null) throw const UpdateFailure('storage');
        received += bytes.length;
        if (received > release.installer.size) {
          throw const UpdateFailure('integrity');
        }
        sink.add(bytes);
        // Back-pressure bounds buffered bytes when storage is slower than HTTP.
        buffered += bytes.length;
        if (buffered >= 1024 * 1024) {
          await sink.flush();
          buffered = 0;
        }
        progress(received, release.installer.size, false);
      }
      await sink.close();
      await done;
      sink = null;
      if (writeError != null) throw const UpdateFailure('storage');
      token.check();
      if (received != release.installer.size) {
        throw const UpdateFailure('integrity');
      }
      progress(received, release.installer.size, true);
      if (await updateFileHash(partial.path) != hash) {
        throw const UpdateFailure('integrity');
      }
      token.check();
      await partial.rename(installer.path);
      return installer;
    } on UpdateFailure {
      rethrow;
    } catch (_) {
      token.check();
      throw const UpdateFailure('storage');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
    }
  }

  Future<void> verify(
    File file,
    AppUpdateRelease release,
    UpdateCancellation token,
  ) async {
    final root = Directory(
      paths.join((await cacheDirectory()).path, 'tsukuyomi-updates'),
    );
    final expected = paths.join(root.path, release.installer.name);
    if (file.path != expected ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() !=
            paths.join(
              await root.resolveSymbolicLinks(),
              release.installer.name,
            ) ||
        await file.length() != release.installer.size) {
      throw const UpdateFailure('integrity');
    }
    final checksum =
        release.installer.digest ??
        updateChecksum(
          await _text(release.checksums.url, 65536, token),
          release.installer,
        );
    if (await updateFileHash(file.path) != checksum) {
      throw const UpdateFailure('integrity');
    }
    token.check();
  }
}
