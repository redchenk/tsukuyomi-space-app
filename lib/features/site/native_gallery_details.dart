import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/room_files.dart';
import 'gallery_copy.dart';
import 'native_asset_service.dart';
import 'site_widgets.dart';

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
    this.fit = BoxFit.contain,
  });
  final Map asset;
  final String site;
  final String? cookie;
  final double? height;
  final bool preview;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final urls = galleryImageUrls(asset, site, preview: preview);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.isFinite
            ? box.maxWidth
            : MediaQuery.sizeOf(context).width;
        final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, preview ? 1200 : 2560);
        Widget imageAt(int index) => index >= urls.length
            ? const Center(child: Icon(Icons.broken_image_outlined))
            : Image.network(
                urls[index],
                headers: galleryMediaHeaders(urls[index], site, cookie),
                fit: fit,
                cacheWidth: cacheWidth,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) => imageAt(index + 1),
              );
        return SizedBox(
          height: height,
          width: double.infinity,
          child: imageAt(0),
        );
      },
    );
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

String galleryImageTitle(Map asset) => nativeAssetName(asset).replaceFirst(
  RegExp(r'\.(?:png|jpe?g|webp|gif|avif|heic)$', caseSensitive: false),
  '',
);

List<String> galleryTags(Map asset) {
  final metadata = asset['metadata'];
  final tags = metadata is Map ? metadata['tags'] : null;
  return tags is List ? tags.whereType<String>().take(12).toList() : const [];
}

/// Redirects may cross to the public CDN. Recompute cookies for each hop.
Future<Uint8List> downloadGalleryBytes(
  Map asset,
  String site,
  String? cookie, {
  http.Client? client,
  bool Function()? isCurrent,
}) async {
  final urls = galleryImageUrls(asset, site, preview: false);
  if (urls.isEmpty) throw const ApiFailure('图片没有可用的下载地址');
  final connection = client ?? http.Client();
  try {
    var target = Uri.parse(urls.first);
    for (var hop = 0; hop < 6; hop++) {
      if (isCurrent?.call() == false) {
        throw const ApiFailure('账号已切换，请重试', status: 409);
      }
      final request = http.Request('GET', target)..followRedirects = false;
      request.headers.addAll(
        galleryMediaHeaders('$target', site, cookie) ?? const {},
      );
      final response = await connection
          .send(request)
          .timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.listen(null).cancel();
        if (location == null) throw const ApiFailure('图片重定向地址无效');
        target = target.resolve(location);
        if (!['http', 'https'].contains(target.scheme)) {
          throw const ApiFailure('图片重定向地址无效');
        }
        continue;
      }
      if (response.statusCode != 200) {
        throw ApiFailure('图片下载失败', status: response.statusCode);
      }
      if ((response.contentLength ?? 0) > maxAttachmentBytes) {
        throw const ApiFailure('单个文件不能超过 100 MB');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (isCurrent?.call() == false) {
          throw const ApiFailure('账号已切换，请重试', status: 409);
        }
        if (bytes.length + part.length > maxAttachmentBytes) {
          throw const ApiFailure('单个文件不能超过 100 MB');
        }
        bytes.add(part);
      }
      return bytes.takeBytes();
    }
    throw const ApiFailure('图片重定向次数过多');
  } finally {
    if (client == null) connection.close();
  }
}

class NativeGalleryViewer extends StatefulWidget {
  const NativeGalleryViewer({
    super.key,
    required this.initial,
    required this.assets,
    required this.site,
    required this.cookie,
    required this.manage,
    required this.level,
    required this.onProfile,
    required this.onCopy,
    required this.onDelete,
    required this.canDelete,
    required this.isCurrent,
  });
  final Map<String, dynamic> initial;
  final List<Map<String, dynamic>> assets;
  final String site;
  final String? cookie;
  final bool manage;
  final int Function(Map<String, dynamic>) level;
  final ValueChanged<Map<String, dynamic>> onProfile;
  final Future<bool> Function(Map<String, dynamic>) onCopy;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  final bool Function(Map<String, dynamic>) canDelete;
  final bool Function() isCurrent;
  @override
  State<NativeGalleryViewer> createState() => _NativeGalleryViewerState();
}

class _NativeGalleryViewerState extends State<NativeGalleryViewer> {
  late Map<String, dynamic> selected = widget.initial;
  final closeFocus = FocusNode();
  http.Client? downloadClient;
  String status = '';
  bool downloading = false;
  int get index =>
      widget.assets.indexWhere((asset) => asset['id'] == selected['id']);
  bool get canBrowse => index >= 0 && widget.assets.length > 1;
  String g(String zh, String en, String ja) => galleryCopy(context, zh, en, ja);
  @override
  void dispose() {
    downloadClient?.close();
    closeFocus.dispose();
    super.dispose();
  }

  void browse(int direction) {
    if (!canBrowse) return;
    setState(
      () =>
          selected = widget.assets[(index + direction) % widget.assets.length],
    );
  }

  Future<void> download() async {
    if (downloading) return;
    final asset = selected;
    final client = http.Client();
    downloadClient = client;
    setState(() {
      downloading = true;
      status = '';
    });
    try {
      final bytes = await downloadGalleryBytes(
        asset,
        widget.site,
        widget.cookie,
        client: client,
        isCurrent: () => mounted && widget.isCurrent(),
      );
      if (!mounted || !widget.isCurrent()) return;
      final saved = await exportRoomFile(
        context,
        bytes,
        nativeAssetName(asset).replaceAll(RegExp(r'[/\\]'), '_'),
        '${asset['mime_type'] ?? 'image/jpeg'}',
      );
      if (mounted && saved) {
        setState(() => status = g('图片已保存', 'Image saved', '画像を保存しました'));
      }
    } catch (e) {
      if (mounted && widget.isCurrent()) setState(() => status = '$e');
    } finally {
      client.close();
      if (identical(downloadClient, client)) downloadClient = null;
      if (mounted) setState(() => downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = selected, colors = Theme.of(context).colorScheme;
    final tags = galleryTags(asset), metadata = mapOf(asset['metadata']);
    final username = '${asset['owner_username'] ?? ''}'.trim();
    final width = metadata['width'] ?? asset['width'];
    final height = metadata['height'] ?? asset['height'];
    final urls = galleryImageUrls(asset, widget.site, preview: false);
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _GalleryBrowseIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _GalleryBrowseIntent(1),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          _GalleryBrowseIntent: CallbackAction<_GalleryBrowseIntent>(
            onInvoke: (intent) {
              browse(intent.direction);
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: Dialog(
          key: const Key('gallery-viewer'),
          insetPadding: const EdgeInsets.all(12),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 1040,
              maxHeight: MediaQuery.sizeOf(context).height - 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            g('图片预览', 'Image preview', '画像プレビュー'),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (canBrowse) ...[
                          IconButton(
                            key: const Key('gallery-viewer-previous'),
                            tooltip: g('上一张图片', 'Previous image', '前の画像'),
                            onPressed: () => browse(-1),
                            icon: const Icon(Icons.arrow_back, size: 18),
                          ),
                          Text(
                            '${index + 1} / ${widget.assets.length}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          IconButton(
                            key: const Key('gallery-viewer-next'),
                            tooltip: g('下一张图片', 'Next image', '次の画像'),
                            onPressed: () => browse(1),
                            icon: const Icon(Icons.arrow_forward, size: 18),
                          ),
                        ],
                        IconButton(
                          key: const Key('gallery-viewer-close'),
                          focusNode: closeFocus,
                          autofocus: true,
                          tooltip: g(
                            '关闭图片预览',
                            'Close image preview',
                            'プレビューを閉じる',
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close, size: 20),
                        ),
                      ],
                    ),
                  ),
                  ColoredBox(
                    color: colors.surfaceContainerLowest,
                    child: InteractiveViewer(
                      key: ValueKey(asset['id']),
                      minScale: 1,
                      maxScale: 5,
                      child: NativeGalleryImage(
                        asset: asset,
                        site: widget.site,
                        cookie: widget.cookie,
                        preview: false,
                        height:
                            (MediaQuery.sizeOf(context).height *
                                    (MediaQuery.sizeOf(context).width < 720
                                        ? .42
                                        : .55))
                                .clamp(120, 580),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          galleryImageTitle(asset),
                          key: const Key('gallery-viewer-title'),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            TextButton(
                              onPressed: username.isEmpty
                                  ? null
                                  : () => widget.onProfile(asset),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  NativeGalleryAvatar(
                                    asset: asset,
                                    site: widget.site,
                                    cookie: widget.cookie,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      username.isEmpty
                                          ? g(
                                              '站点归档',
                                              'Site archive',
                                              'サイトアーカイブ',
                                            )
                                          : galleryUploaderName(asset),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if ('${asset['owner_id'] ?? ''}'
                                      .isNotEmpty) ...[
                                    const SizedBox(width: 6),
                                    NativeUserLevelBadge(
                                      level: widget.level(asset),
                                      compact: true,
                                      showTitle: false,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Text(
                              dateText(asset['created_at']),
                              style: const TextStyle(fontSize: 11),
                            ),
                            if (width is num &&
                                height is num &&
                                width > 0 &&
                                height > 0)
                              Text(
                                '$width × $height',
                                style: const TextStyle(fontSize: 11),
                              ),
                          ],
                        ),
                        if (tags.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in tags)
                                Chip(
                                  label: Text(
                                    tag,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (widget.manage)
                              OutlinedButton.icon(
                                onPressed: () async {
                                  final copied = await widget.onCopy(asset);
                                  if (mounted && copied) {
                                    setState(
                                      () => status = g(
                                        'Markdown 已复制',
                                        'Markdown copied',
                                        'Markdown をコピーしました',
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.copy, size: 16),
                                label: const Text('Markdown'),
                              ),
                            OutlinedButton.icon(
                              onPressed: urls.isEmpty
                                  ? null
                                  : () => openSiteLink(widget.site, urls.first),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              label: Text(
                                g('打开原图', 'Open original', '元の画像を開く'),
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: downloading ? null : download,
                              icon: const Icon(Icons.download, size: 16),
                              label: Text(
                                downloading
                                    ? g('正在下载…', 'Downloading…', 'ダウンロード中…')
                                    : g('下载', 'Download', 'ダウンロード'),
                              ),
                            ),
                            if (widget.manage && widget.canDelete(asset))
                              TextButton.icon(
                                onPressed: () => widget.onDelete(asset),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 16,
                                ),
                                label: Text(g('删除', 'Delete', '削除')),
                              ),
                          ],
                        ),
                        if (status.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(status),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GalleryBrowseIntent extends Intent {
  const _GalleryBrowseIntent(this.direction);
  final int direction;
}
