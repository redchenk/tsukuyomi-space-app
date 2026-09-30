import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';

/// The source gallery attempts its small preview once, then the original URL.
/// A broken original never starts another retry or creates an image loop.
List<String> galleryImageUrls(Map asset, String site, {bool preview = true}) {
  String first(List<String> keys) {
    for (final key in keys) {
      final value = '${asset[key] ?? ''}'.trim();
      if (value.isEmpty) continue;
      final target = endpointUri(site).resolve(value);
      if (['http', 'https'].contains(target.scheme)) return '$target';
    }
    return '';
  }

  final small = first(['preview_url', 'access_url', 'display_url', 'url']);
  final full = first([
    'access_url',
    'display_url',
    'markdown_url',
    'url',
    'preview_url',
  ]);
  return {
    if (preview && small.isNotEmpty) small,
    if (full.isNotEmpty) full,
  }.toList();
}

Map<String, String>? galleryMediaHeaders(
  String url,
  String site,
  String? cookie,
) =>
    cookie != null &&
        endpointUri(site).resolve(url).origin == endpointUri(site).origin
    ? {'Cookie': cookie}
    : null;

class NativeGalleryImage extends StatelessWidget {
  const NativeGalleryImage({
    super.key,
    required this.asset,
    required this.site,
    this.cookie,
    this.height = 200,
    this.preview = true,
  });
  final Map asset;
  final String site;
  final String? cookie;
  final double height;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final urls = galleryImageUrls(asset, site, preview: preview);
    Widget imageAt(int index) => index >= urls.length
        ? const Center(child: Icon(Icons.broken_image_outlined))
        : Image.network(
            urls[index],
            headers: galleryMediaHeaders(urls[index], site, cookie),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => imageAt(index + 1),
          );
    return SizedBox(height: height, width: double.infinity, child: imageAt(0));
  }
}

String galleryUploaderName(Map asset) {
  return userDisplayName(asset, prefix: 'owner', fallback: '站点归档');
}

String galleryUploaderAvatar(Map asset, String site) {
  final direct = '${asset['owner_avatar_url'] ?? ''}'.trim();
  final parsed = Uri.tryParse(direct);
  if (parsed?.scheme.toLowerCase() == 'https' && parsed!.host.isNotEmpty) {
    return direct;
  }
  final name = '${asset['owner_username'] ?? ''}'.trim();
  if (asset['owner_has_avatar'] != true || name.isEmpty) return '';
  final version = '${asset['owner_avatar_updated_at'] ?? ''}'.trim();
  return endpointUri(site)
      .resolve(
        '/api/user/public/${Uri.encodeComponent(name)}/avatar${version.isEmpty ? '' : '?v=${Uri.encodeComponent(version)}'}',
      )
      .toString();
}

class NativeGalleryAvatar extends StatelessWidget {
  const NativeGalleryAvatar({
    super.key,
    required this.asset,
    required this.site,
    this.cookie,
    this.size = 28,
  });
  final Map asset;
  final String site;
  final String? cookie;
  final double size;
  @override
  Widget build(BuildContext context) {
    final name = galleryUploaderName(asset),
        url = galleryUploaderAvatar(asset, site);
    final fallback = Center(
      child: Text(String.fromCharCode(name.runes.first).toUpperCase()),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SizedBox(
            width: size,
            height: size,
            child: url.isEmpty
                ? fallback
                : Image.network(
                    url,
                    headers: galleryMediaHeaders(url, site, cookie),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => fallback,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Only public level data is cached, for the same five minutes as the site.
/// Origin changes cannot mix levels from two independent installations.
class NativePublicUserLevels {
  NativePublicUserLevels(this.controller, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final RoomController controller;
  final DateTime Function() now;
  final _cache = <String, ({int level, DateTime at})>{};
  final _requests = <String, Future<void>>{};
  String _origin = '';
  int level(Object? id) => _cache['$id']?.level ?? 1;
  Future<void> hydrate(Iterable<Object?> userIds, {bool force = false}) async {
    final origin = endpointUri(controller.settings.siteUrl).origin;
    if (_origin != origin) {
      _origin = origin;
      _cache.clear();
    }
    if (controller.site is! SiteDataService) return;
    final ids = userIds
        .map((id) => '${id ?? ''}'.trim())
        .where((id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id))
        .toSet()
        .take(60);
    final missing =
        ids
            .where(
              (id) =>
                  force ||
                  !_cache.containsKey(id) ||
                  now().difference(_cache[id]!.at) > const Duration(minutes: 5),
            )
            .toList()
          ..sort();
    if (missing.isEmpty) return;
    final key = '$origin:${missing.join(',')}';
    final task = _requests.putIfAbsent(key, () => _load(origin, missing));
    try {
      await task;
    } finally {
      if (identical(_requests[key], task)) _requests.remove(key);
    }
  }

  Future<void> _load(String origin, List<String> ids) async {
    final response = await (controller.site as SiteDataService).request(
      controller.settings.siteUrl,
      'GET',
      '/api/growth/public?ids=${Uri.encodeComponent(ids.join(','))}',
    );
    if (_origin != origin ||
        endpointUri(controller.settings.siteUrl).origin != origin) {
      return;
    }
    if (response['success'] != true) throw const ApiFailure('无法读取公开成长等级');
    for (final item
        in (response['data'] is List ? response['data'] as List : const [])
            .whereType<Map>()) {
      final id = '${item['userId'] ?? ''}'.trim();
      if (ids.contains(id)) {
        final raw = item['level'];
        final value = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 1;
        _cache[id] = (level: value.clamp(1, 9), at: now());
      }
    }
  }
}

class NativeUserLevelBadge extends StatelessWidget {
  const NativeUserLevelBadge({
    super.key,
    required this.level,
    this.compact = false,
    this.showTitle = true,
  });
  final int level;
  final bool compact, showTitle;
  static const titles = {
    'zh': [
      '初次连接',
      '微光相识',
      '月下同行',
      '心声共鸣',
      '记忆同调',
      '星海相伴',
      '月之眷属',
      '永恒月契',
      '八千代之约',
    ],
    'ja': [
      '初めての接続',
      '微光の出会い',
      '月下の同行',
      '心の共鳴',
      '記憶の同調',
      '星海の伴侶',
      '月の眷属',
      '永遠の月契',
      '八千代の契り',
    ],
    'en': [
      'First Connection',
      'Glimmering Bond',
      'Moonlit Journey',
      'Resonant Hearts',
      'Memory Sync',
      'Starlit Companion',
      'Moonbound',
      'Eternal Moon Pact',
      "Yachiyo's Covenant",
    ],
  };
  @override
  Widget build(BuildContext context) {
    final value = level.clamp(1, 9),
        language = SiteLocaleScope.maybeOf(context)?.language ?? 'zh';
    final title = titles[language]![value - 1];
    final label = language == 'en'
        ? 'Level $value, $title'
        : language == 'ja'
        ? 'レベル $value、$title'
        : '等级 $value，$title';
    final color = const [
      Color(0xff768095),
      Color(0xff2a9caf),
      Color(0xffb88720),
      Color(0xffd74f84),
      Color(0xff765fc4),
    ][(value - 1) ~/ 2];
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color.withValues(alpha: .14),
              border: Border.all(color: color.withValues(alpha: .62)),
              borderRadius: BorderRadius.circular(99),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 9,
                vertical: compact ? 3 : 4,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    value >= 7 ? Icons.auto_awesome : Icons.workspace_premium,
                    size: compact ? 12 : 14,
                    color: color,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Lv.$value',
                    style: TextStyle(
                      fontSize: compact ? 10 : 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (showTitle) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(title, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
