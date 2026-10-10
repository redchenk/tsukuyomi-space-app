const appRepository = 'https://github.com/redchenk/tsukuyomi-space-app';
final appReleasesApi = Uri.parse(
  'https://api.github.com/repos/redchenk/tsukuyomi-space-app/releases?per_page=30',
);

class UpdateFailure implements Exception {
  const UpdateFailure(this.code);
  final String code;
}

/// Numeric SemVer ordering, including beta.10 > beta.2 and stable > beta.
class AppVersion implements Comparable<AppVersion> {
  AppVersion._(this.core, this.pre, this.value);
  final List<BigInt> core;
  final List<String> pre;
  final String value;
  static AppVersion? parse(String value) {
    if (value.length > 128) return null;
    final match = RegExp(
      r'^v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final pre = match[2]?.split('.') ?? <String>[];
    if (pre.any((s) => RegExp(r'^0\d+$').hasMatch(s))) return null;
    return AppVersion._(
      match[1]!.split('.').map(BigInt.parse).toList(),
      pre,
      value,
    );
  }

  String get base => core.join('.');
  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final c = core[i].compareTo(other.core[i]);
      if (c != 0) return c;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = BigInt.tryParse(pre[i]), b = BigInt.tryParse(other.pre[i]);
      final c = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : pre[i].compareTo(other.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

enum UpdatePlatform { androidArm64, androidX64, windows, macos, linux, ios }

extension UpdatePlatformAsset on UpdatePlatform {
  String get suffix => switch (this) {
    UpdatePlatform.androidArm64 => 'android-arm64-v8a.apk',
    UpdatePlatform.androidX64 => 'android-x86_64.apk',
    UpdatePlatform.windows => 'windows-x64-setup.exe',
    UpdatePlatform.macos => 'macos-universal.dmg',
    UpdatePlatform.linux => 'linux-x64.deb',
    UpdatePlatform.ios => 'ios-arm64-unsigned.ipa',
  };
  String get label => switch (this) {
    UpdatePlatform.androidArm64 => 'Android · ARM64',
    UpdatePlatform.androidX64 => 'Android · x86_64',
    UpdatePlatform.windows => 'Windows · x64',
    UpdatePlatform.macos => 'macOS · Universal',
    UpdatePlatform.linux => 'Linux · x64',
    UpdatePlatform.ios => 'iOS · ARM64',
  };
}

class UpdateAsset {
  const UpdateAsset(this.name, this.url, this.size, this.digest);
  final String name;
  final Uri url;
  final int size;
  final String? digest;
  static UpdateAsset? parse(Object? data, String tag, String name) {
    if (data is! Map || data['name'] != name || data['state'] != 'uploaded') {
      return null;
    }
    final size = data['size'];
    final url = Uri.tryParse('${data['browser_download_url']}');
    final expected = Uri.parse('$appRepository/releases/download/$tag/$name');
    if (size is! int ||
        size <= 0 ||
        size > 2 * 1024 * 1024 * 1024 ||
        url != expected) {
      return null;
    }
    final digest = data['digest'];
    if (digest != null &&
        !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch('$digest')) {
      return null;
    }
    return UpdateAsset(
      name,
      url!,
      size,
      digest == null ? null : '$digest'.substring(7),
    );
  }
}

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.installer,
    required this.checksums,
    required this.publishedAt,
  });
  final String tag, notes;
  final AppVersion version;
  final UpdateAsset installer, checksums;
  final DateTime? publishedAt;
  Uri get url => Uri.parse('$appRepository/releases/tag/$tag');
  static AppUpdateRelease? parse(Object? data, UpdatePlatform platform) {
    if (data is! Map || data['draft'] != false || data['prerelease'] is! bool) {
      return null;
    }
    final tag = '${data['tag_name']}';
    if (!RegExp(r'^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$').hasMatch(tag)) {
      return null;
    }
    final version = AppVersion.parse(tag);
    if (version == null ||
        (data['prerelease'] == true) != version.pre.isNotEmpty ||
        data['html_url'] != '$appRepository/releases/tag/$tag') {
      return null;
    }
    final assets = data['assets'];
    if (assets is! List || assets.length > 100) return null;
    UpdateAsset? asset(String name) {
      final matches = assets
          .where((a) => a is Map && a['name'] == name)
          .toList();
      return matches.length == 1
          ? UpdateAsset.parse(matches.single, tag, name)
          : null;
    }

    final installer = asset(
      'tsukuyomi-space-${version.base}-${platform.suffix}',
    );
    final checksums = asset('SHA256SUMS.txt');
    if (installer == null || checksums == null || checksums.size > 65536) {
      return null;
    }
    final notes = '${data['body'] ?? ''}';
    return AppUpdateRelease(
      tag: tag,
      version: version,
      notes: notes.length > 20000 ? notes.substring(0, 20000) : notes,
      installer: installer,
      checksums: checksums,
      publishedAt: DateTime.tryParse('${data['published_at']}'),
    );
  }
}

AppUpdateRelease? selectAppUpdate(
  Object? catalog,
  AppVersion installed,
  UpdatePlatform platform, {
  required bool previews,
}) {
  if (catalog is! List) throw const UpdateFailure('metadata');
  final candidates =
      catalog
          .take(100)
          .map((item) => AppUpdateRelease.parse(item, platform))
          .whereType<AppUpdateRelease>()
          .where(
            (r) =>
                (previews || r.version.pre.isEmpty) &&
                r.version.compareTo(installed) > 0,
          )
          .toList()
        ..sort((a, b) => b.version.compareTo(a.version));
  return candidates.isEmpty ? null : candidates.first;
}

String updateChecksum(String source, UpdateAsset asset) {
  final hashes = <String>[];
  for (final line in source.split('\n')) {
    final match = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$')
        .firstMatch(line.trimRight());
    if (match != null && match[2] == asset.name) {
      hashes.add(match[1]!.toLowerCase());
    }
  }
  if (hashes.length != 1 ||
      (asset.digest != null && hashes.single != asset.digest)) {
    throw const UpdateFailure('integrity');
  }
  return hashes.single;
}
