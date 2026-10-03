import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import 'content_page_shell.dart';
import 'login_dialog.dart';
import 'native_asset_service.dart';
import 'native_gallery_details.dart';
import 'gallery_copy.dart';
import 'native_media_view.dart';
import 'site_widgets.dart';

class GalleryPage extends StatelessWidget {
  const GalleryPage({
    super.key,
    required this.controller,
    required this.path,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  Widget build(BuildContext context) => AssetLibraryPage(
    controller: controller,
    path: path,
    gallery: true,
    onGo: onGo,
    onTheme: onTheme,
  );
}

class AttachmentsPage extends StatelessWidget {
  const AttachmentsPage({
    super.key,
    required this.controller,
    required this.path,
    required this.onGo,
    this.onTheme,
    this.onSelect,
    this.imageOnly = false,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final ValueChanged<Map<String, dynamic>>? onSelect;
  final bool imageOnly;
  @override
  Widget build(BuildContext context) => AssetLibraryPage(
    controller: controller,
    path: path,
    gallery: false,
    onGo: onGo,
    onTheme: onTheme,
    onSelect: onSelect,
    imageOnly: imageOnly,
  );
}

class AssetLibraryPage extends StatefulWidget {
  const AssetLibraryPage({
    super.key,
    required this.controller,
    required this.path,
    required this.gallery,
    required this.onGo,
    this.onTheme,
    this.onSelect,
    this.imageOnly = false,
    this.service,
    this.pickFile,
  });
  final RoomController controller;
  final String path;
  final bool gallery, imageOnly;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final ValueChanged<Map<String, dynamic>>? onSelect;
  final NativeAssetService? service;
  final Future<XFile?> Function()? pickFile;
  @override
  State<AssetLibraryPage> createState() => _AssetLibraryPageState();
}

class _AssetLibraryPageState extends State<AssetLibraryPage>
    with WidgetsBindingObserver {
  late final NativeAssetService service;
  late final NativePublicUserLevels userLevels;
  final search = TextEditingController();
  List<Map<String, dynamic>> assets = [], pending = [];
  bool loading = true, uploading = false, admin = false, randomLoading = false;
  String category = '', sort = 'latest';
  bool lastAuthenticated = false;
  int galleryColumns = 4;
  Route<void>? viewerRoute;
  String error = '',
      notice = '',
      type = 'all',
      storageMode = 'auto',
      scope = 'mine',
      owner = '',
      phase = '';
  double? progress;
  int page = 1, pages = 1, total = 0, requestId = 0, randomRequest = 0;
  AssetUploadCancellation? upload;
  RoomController get c => widget.controller;
  bool get manage =>
      widget.gallery && Uri.parse(widget.path).path.endsWith('/manage');
  bool get private => !widget.gallery || manage;
  bool get authed => c.account != null && !c.sessionExpired;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service = widget.service ?? NativeAssetService(c);
    userLevels = NativePublicUserLevels(c);
    owner = service.scope;
    lastAuthenticated = authed;
    type = widget.imageOnly ? 'image' : 'all';
    c.addListener(accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) load();
    });
  }

  void accountChanged() {
    if (!mounted) return;
    if (owner != service.scope || lastAuthenticated != authed) {
      owner = service.scope;
      lastAuthenticated = authed;
      requestId++;
      randomRequest++;
      if (viewerRoute?.isActive == true) {
        Navigator.of(context, rootNavigator: true).removeRoute(viewerRoute!);
      }
      upload?.cancel();
      uploading = false;
      upload = null;
      assets = [];
      randomLoading = false;
      pending = [];
      admin = false;
      scope = 'mine';
      notice = '';
      page = 1;
      load();
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      load();
    }
  }

  @override
  void dispose() {
    requestId++;
    randomRequest++;
    upload?.cancel();
    c.removeListener(accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    super.dispose();
  }

  Future<void> load({int? requestedPage}) async {
    final ticket = ++requestId, current = service.scope;
    setState(() {
      loading = true;
      error = '';
    });
    if (private && !authed) {
      setState(() => loading = false);
      return;
    }
    final limit = widget.gallery
        ? 12
        : MediaQuery.sizeOf(context).width < 760
        ? 18
        : 36;
    try {
      if (authed) {
        final canModerate = await service.moderator();
        if (!mounted || current != service.scope || ticket != requestId) return;
        admin = canModerate;
        if (admin && Uri.parse(widget.path).queryParameters['scope'] == 'all') {
          scope = 'all';
        }
      }
      final params = <String, String>{
        'page': '${requestedPage ?? page}',
        'limit': '$limit',
        'search': search.text.trim(),
        if (!widget.gallery) 'type': type,
        if (widget.gallery) 'category': category,
        if (widget.gallery) 'sort': sort,
        if (manage) 'scope': admin ? 'all' : 'mine',
        if (!widget.gallery && admin && scope == 'all') 'scope': 'all',
      };
      final path =
          '${widget.gallery ? '/api/assets/gallery' : '/api/assets'}?${Uri(queryParameters: params).query}';
      final doc = await service.repository.read(path, private: private);
      if (!mounted || current != service.scope || ticket != requestId) return;
      final data = mapOf(doc.data),
          pagination = mapOf(mapOf(doc.data)['pagination']);
      setState(() {
        assets = rowsOf(data['assets']);
        page = (pagination['page'] as num? ?? 1).toInt();
        pages = (pagination['totalPages'] as num? ?? 1).toInt().clamp(
          1,
          999999,
        );
        total = (pagination['total'] as num? ?? assets.length).toInt();
        notice = doc.notice;
      });
      if (widget.gallery) {
        unawaited(hydrateLevels(assets, ticket: ticket));
      }
      if (!widget.gallery) {
        await loadPending();
      }
    } catch (e) {
      if (mounted && current == service.scope && ticket == requestId) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && current == service.scope && ticket == requestId) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> browseRandom() async {
    if (randomLoading) return;
    final current = service.scope, ticket = ++randomRequest;
    setState(() => randomLoading = true);
    try {
      final doc = await service.request(
        'GET',
        '/api/assets/gallery/public?limit=1&random=1',
      );
      if (!mounted || current != service.scope || ticket != randomRequest) {
        return;
      }
      if (doc['success'] != true) {
        throw ApiFailure('${doc['message'] ?? '无法读取随机图片'}');
      }
      final asset = rowsOf(mapOf(doc['data'])['assets']).firstOrNull;
      if (asset == null) {
        setState(
          () => notice = galleryCopy(
            context,
            '图库暂时还没有图片',
            'No images in the gallery yet',
            'ギャラリーにはまだ画像がありません',
          ),
        );
      } else {
        unawaited(hydrateLevels([asset]));
        unawaited(preview(asset));
      }
    } catch (e) {
      if (mounted && current == service.scope && ticket == randomRequest) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && current == service.scope && ticket == randomRequest) {
        setState(() => randomLoading = false);
      }
    }
  }

  Future<void> hydrateLevels(
    List<Map<String, dynamic>> rows, {
    int? ticket,
  }) async {
    final current = service.scope;
    try {
      await userLevels.hydrate(rows.map((asset) => asset['owner_id']));
      if (mounted &&
          current == service.scope &&
          (ticket == null || ticket == requestId)) {
        setState(() {});
      }
    } catch (_) {
      // An unavailable public badge must not hide the gallery itself.
    }
  }

  Future<void> loadPending() async {
    final current = service.scope;
    try {
      final doc = await service.request('GET', '/api/assets/uploads');
      if (mounted && current == service.scope) {
        setState(() => pending = rowsOf(doc['data']));
      }
    } catch (_) {}
  }

  Future<void> chooseAndUpload() async {
    if (uploading) return;
    if (!authed) {
      await showSiteLogin(context, c);
      return;
    }
    final current = service.scope;
    final file =
        await (widget.pickFile?.call() ??
            openFile(
              acceptedTypeGroups: [
                XTypeGroup(
                  label: widget.gallery || widget.imageOnly ? '图片' : '附件',
                  extensions: attachmentMimeTypes.keys
                      .where(
                        (extension) =>
                            !(widget.gallery || widget.imageOnly) ||
                            attachmentMimeTypes[extension]!.startsWith(
                              'image/',
                            ),
                      )
                      .toList(),
                ),
              ],
            ));
    if (file == null || !mounted || current != service.scope) return;
    AssetUploadFile selected;
    try {
      selected = await AssetUploadFile.fromXFile(file);
    } catch (e) {
      if (mounted && current == service.scope) {
        setState(() => error = '无法读取所选文件：$e');
      }
      return;
    }
    if (!mounted || current != service.scope) return;
    if ((widget.gallery || widget.imageOnly) &&
        !selected.mime.startsWith('image/')) {
      setState(() => error = '请选择图片文件');
      return;
    }
    upload = AssetUploadCancellation();
    setState(() {
      uploading = true;
      error = '';
      progress = 0;
      phase = '正在检查文件…';
    });
    try {
      Map<String, dynamic> asset;
      if (widget.gallery) {
        if (selected.size > maxAttachmentBytes) {
          throw const ApiFailure('单个文件不能超过 100 MB');
        }
        final bytes = await selected.readRange(0, selected.size);
        final compressed = await _galleryImage(bytes);
        if (!mounted || current != service.scope) return;
        upload!.check();
        setState(() {
          phase = '正在上传…';
          progress = .2;
        });
        final result = await service.request('POST', '/api/assets', {
          'dataUrl': 'data:image/jpeg;base64,${base64Encode(compressed)}',
          'fileName': selected.name,
          'mimeType': 'image/jpeg',
          'alt': '图库图片',
          'collection': 'gallery',
        });
        asset = mapOf(result['data']);
      } else {
        asset = await service.upload(
          selected,
          storage: storageMode,
          cancellation: upload,
          onProgress: (value, label) {
            if (mounted && current == service.scope) {
              setState(() {
                progress = value;
                phase = label;
              });
            }
          },
        );
      }
      if (!mounted || current != service.scope) return;
      if (widget.gallery) {
        search.clear();
        category = '';
        sort = 'latest';
      }
      await load(requestedPage: 1);
      if (mounted && current == service.scope) {
        setState(() => notice = widget.gallery ? '图片已加入图库' : '附件已上传');
        widget.onSelect?.call(asset);
      }
    } catch (e) {
      if (mounted && current == service.scope) {
        setState(() => error = '$e');
      }
    } finally {
      if (mounted && current == service.scope) {
        setState(() {
          uploading = false;
          phase = '';
          progress = null;
        });
      }
      if (!widget.gallery && current == service.scope) {
        await loadPending();
      }
    }
  }

  Future<void> delete(Map<String, dynamic> asset) async {
    final current = service.scope;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${nativeAssetName(asset)}」？'),
        content: const SiteText('已插入文章的资源链接可能会失效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const SiteText('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted || current != service.scope) return;
    try {
      await service.request(
        'DELETE',
        '/api/assets/${Uri.encodeComponent('${asset['id']}')}',
      );
      if (mounted && current == service.scope) {
        await load();
        if (mounted && current == service.scope) {
          setState(() => notice = '附件已删除');
        }
      }
    } catch (e) {
      if (mounted && current == service.scope) {
        setState(() => error = '$e');
      }
    }
  }

  Future<bool> copy(Map<String, dynamic> asset) async {
    final current = service.scope;
    try {
      await Clipboard.setData(ClipboardData(text: nativeAssetMarkdown(asset)));
      if (mounted && current == service.scope) {
        setState(() => notice = 'Markdown 已复制，可以直接粘贴到文章正文');
        return true;
      }
    } catch (_) {
      if (mounted && current == service.scope) {
        setState(() => error = '复制失败，请重试');
      }
    }
    return false;
  }

  Future<void> preview(Map<String, dynamic> asset) async {
    if (!widget.gallery) return attachmentPreview(asset);
    final previewScope = service.scope, previewAuthenticated = authed;
    final route = DialogRoute<void>(
      context: context,
      barrierColor: const Color(0xb8090c18),
      builder: (context) => NativeGalleryViewer(
        initial: asset,
        assets: List.unmodifiable(assets),
        site: c.settings.siteUrl,
        cookie: c.site.cookie,
        manage: manage,
        level: (asset) => userLevels.level(asset['owner_id']),
        onProfile: (asset) {
          Navigator.of(context).pop();
          widget.onGo(
            '/users/${Uri.encodeComponent('${asset['owner_username']}')}',
          );
        },
        onCopy: copy,
        onDelete: (asset) async {
          Navigator.of(context).pop();
          await delete(asset);
        },
        canDelete: (asset) =>
            authed && (admin || '${asset['owner_id']}' == c.account?.id),
        isCurrent: () =>
            mounted &&
            previewScope == service.scope &&
            previewAuthenticated == authed,
      ),
    );
    viewerRoute = route;
    await Navigator.of(context, rootNavigator: true).push(route);
    if (identical(viewerRoute, route)) viewerRoute = null;
  }

  Future<void> attachmentPreview(Map<String, dynamic> asset) =>
      showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 800),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(nativeAssetName(asset))),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Flexible(
                    child: '${asset['mime_type'] ?? ''}'.startsWith('image/')
                        ? InteractiveViewer(child: _image(asset, height: 600))
                        : NativeMediaView(
                            url: endpointUri(c.settings.siteUrl)
                                .resolve(nativeAssetUrl(asset))
                                .toString(),
                            headers: _assetHeaders(nativeAssetUrl(asset)),
                          ),
                  ),
                  if (widget.gallery) uploader(asset, dismissPreview: true),
                ],
              ),
            ),
          ),
        ),
      );
  Widget _image(Map asset, {double height = 200}) {
    return NativeGalleryImage(
      asset: asset,
      site: c.settings.siteUrl,
      cookie: c.site.cookie,
      height: height,
      preview: widget.gallery,
    );
  }

  Widget uploader(Map<String, dynamic> asset, {bool dismissPreview = false}) {
    final name = '${asset['owner_username'] ?? ''}'.trim();
    return TextButton(
      onPressed: name.isEmpty
          ? null
          : () {
              if (dismissPreview) Navigator.pop(context);
              widget.onGo('/users/${Uri.encodeComponent(name)}');
            },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          NativeGalleryAvatar(
            asset: asset,
            site: c.settings.siteUrl,
            cookie: c.site.cookie,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: name.isEmpty
                ? const SiteText('站点归档')
                : Text(
                    galleryUploaderName(asset),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if ('${asset['owner_id'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(width: 8),
            NativeUserLevelBadge(
              level: userLevels.level(asset['owner_id']),
              compact: true,
              showTitle: false,
            ),
          ],
        ],
      ),
    );
  }

  Map<String, String>? _assetHeaders(String value) {
    return galleryMediaHeaders(value, c.settings.siteUrl, c.site.cookie);
  }

  Widget card(Map<String, dynamic> asset) {
    final image = '${asset['mime_type'] ?? ''}'.startsWith('image/');
    final media =
        '${asset['mime_type'] ?? ''}'.startsWith('audio/') ||
        '${asset['mime_type'] ?? ''}'.startsWith('video/');
    final canDelete =
        admin ||
        (asset['owner_id'] != null && '${asset['owner_id']}' == c.account?.id);
    return SiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (image)
            InkWell(onTap: () => preview(asset), child: _image(asset))
          else if (media)
            NativeMediaView(
              url: endpointUri(c.settings.siteUrl)
                  .resolve(nativeAssetUrl(asset))
                  .toString(),
              headers: _assetHeaders(nativeAssetUrl(asset)),
            )
          else
            SizedBox(
              height: 120,
              child: Center(
                child: Icon(
                  '${asset['mime_type']}'.startsWith('audio/')
                      ? Icons.audio_file
                      : '${asset['mime_type']}'.startsWith('video/')
                      ? Icons.video_file
                      : Icons.insert_drive_file,
                  size: 48,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Text(
            nativeAssetName(asset),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '${asset['mime_type'] ?? 'file'} · ${dateText(asset['created_at'])}',
            style: const TextStyle(fontSize: 12),
          ),
          if (widget.gallery) uploader(asset),
          Wrap(
            spacing: 6,
            children: [
              if (widget.onSelect != null)
                FilledButton(
                  onPressed: () => widget.onSelect!(asset),
                  child: const SiteText('插入'),
                ),
              TextButton(
                onPressed: () => copy(asset),
                child: const SiteText('复制 Markdown'),
              ),
              TextButton(
                onPressed: () => image || media
                    ? preview(asset)
                    : openSiteLink(c.settings.siteUrl, nativeAssetUrl(asset)),
                child: SiteText(image || media ? '预览' : '打开'),
              ),
              if (canDelete && (!widget.gallery || manage))
                TextButton(
                  onPressed: () => delete(asset),
                  child: const SiteText('删除'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ContentPageShell(
    controller: c,
    title: widget.gallery
        ? manage
              ? '图库管理'
              : '图库'
        : widget.onSelect != null
        ? '选择附件'
        : '附件库',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    loading: loading,
    error: error,
    notice: notice,
    onRefresh: load,
    maxWidth: widget.gallery ? 1336 : 1200,
    child: widget.gallery ? _galleryBody() : _libraryBody(),
  );

  String g(String zh, String en, String ja) => galleryCopy(context, zh, en, ja);

  Widget _galleryBody() {
    final canBrowse = !manage || authed;
    final title = manage
        ? (admin
              ? g('全部图库', 'All galleries', '全員のギャラリー')
              : g('我的图库', 'My gallery', 'マイギャラリー'))
        : g('图库', 'Gallery', 'ギャラリー');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            TextButton(
              onPressed: () => widget.onGo('/hub'),
              child: Text(g('首页', 'Home', 'ホーム')),
            ),
            const Icon(Icons.chevron_right, size: 14),
            Text(
              g('图库', 'Gallery', 'ギャラリー'),
              style: const TextStyle(fontSize: 11),
            ),
            if (manage) ...[
              const Icon(Icons.chevron_right, size: 14),
              Text(title, style: const TextStyle(fontSize: 11)),
            ],
          ],
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, box) {
            final heading = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: box.maxWidth < 720 ? 29 : 38,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    Text(
                      manage ? 'GALLERY MANAGER' : 'GALLERY',
                      style: const TextStyle(fontSize: 10, letterSpacing: 2),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  manage
                      ? g(
                          '上传喜欢的画面，管理图库里的每一张图片。',
                          'Upload favourite moments and manage your images.',
                          'お気に入りの一瞬をアップロードして、画像を管理しましょう。',
                        )
                      : g(
                          '收藏插画、截图与壁纸，把喜欢的画面留在这里。',
                          'A home for illustrations, screenshots and wallpapers you love.',
                          'イラスト、スクリーンショット、壁紙。お気に入りの景色をここに。',
                        ),
                  style: const TextStyle(fontSize: 13, height: 1.75),
                ),
              ],
            );
            final actions = Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: () =>
                      widget.onGo(manage ? '/gallery' : '/gallery/manage'),
                  icon: Icon(
                    manage ? Icons.image_outlined : Icons.grid_view,
                    size: 17,
                  ),
                  label: Text(
                    manage
                        ? g('公开图库', 'Public gallery', '公開ギャラリー')
                        : g('我的图库', 'My gallery', 'マイギャラリー'),
                  ),
                ),
                FilledButton.icon(
                  key: const Key('gallery-upload'),
                  onPressed: uploading ? null : chooseAndUpload,
                  icon: const Icon(Icons.upload, size: 17),
                  label: Text(
                    uploading
                        ? g('正在上传', 'Uploading', 'アップロード中')
                        : g('上传图片', 'Upload image', '画像をアップロード'),
                  ),
                ),
              ],
            );
            if (box.maxWidth <
                900 * MediaQuery.textScalerOf(context).scale(1)) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, const SizedBox(height: 18), actions],
              );
            }
            return Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 24),
                actions,
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        if (!canBrowse)
          SiteCard(
            child: Column(
              children: [
                Text(
                  g(
                    '登录后上传图片、管理自己的图库，或复制图片 Markdown。公开图库无需登录即可浏览。',
                    'Sign in to upload images, manage your gallery and copy image Markdown. The public gallery is open to everyone.',
                    'ログインして画像のアップロード、管理、Markdown のコピーができます。公開ギャラリーはどなたでも閲覧できます。',
                  ),
                  style: const TextStyle(height: 1.8),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => showSiteLogin(context, c),
                  child: Text(g('去登录', 'Sign in', 'ログイン')),
                ),
              ],
            ),
          )
        else ...[
          if (uploading)
            SiteCard(
              child: Column(
                children: [
                  SiteText(phase),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress),
                ],
              ),
            ),
          if (manage)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: SiteCard(
                child: Row(
                  children: [
                    const Icon(Icons.upload_outlined, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        g(
                          '点击「上传图片」选择图片。图库图片将公开展示。',
                          'Choose Upload image to select a file. Gallery uploads are public.',
                          '「画像をアップロード」から画像を選択してください。アップロードした画像は公開されます。',
                        ),
                        style: const TextStyle(fontSize: 12, height: 1.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          _galleryDiscovery(),
          const SizedBox(height: 24),
          if (assets.isNotEmpty)
            LayoutBuilder(
              builder: (context, box) {
                final scale = MediaQuery.textScalerOf(context).scale(1);
                final columns = box.maxWidth < 250 * scale
                    ? 1
                    : box.maxWidth < 700 * scale
                    ? 2
                    : box.maxWidth < 1000 * scale
                    ? 3
                    : galleryColumns;
                final gap = box.maxWidth < 700
                    ? 12.0
                    : box.maxWidth < 1000
                    ? 16.0
                    : 22.0;
                final width = (box.maxWidth - (columns - 1) * gap) / columns;
                return Wrap(
                  key: ValueKey('gallery-grid-$columns'),
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final asset in assets)
                      SizedBox(
                        width: width,
                        child: _galleryCard(
                          asset,
                          showLevel: box.maxWidth >= 1000 * scale,
                        ),
                      ),
                  ],
                );
              },
            ),
          if (!loading && assets.isEmpty)
            SiteCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Column(
                  children: [
                    const Icon(Icons.image_outlined, size: 30),
                    const SizedBox(height: 12),
                    Text(
                      search.text.isNotEmpty || category.isNotEmpty
                          ? g('没有找到匹配的图片', 'No matching images', '一致する画像がありません')
                          : g('还没有图片', 'No images yet', 'まだ画像がありません'),
                      style: const TextStyle(fontSize: 22),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      search.text.isNotEmpty || category.isNotEmpty
                          ? g(
                              '筛选会匹配图片的名称、标签和描述。试试其他关键词，或查看全部图片。',
                              'Filters match image names, tags and descriptions. Try another keyword, or browse all images.',
                              '画像名、タグ、説明を検索します。別のキーワードを試すか、すべての画像をご覧ください。',
                            )
                          : g(
                              '从「上传图片」开始，分享喜欢的画面。',
                              'Upload an image to share a favourite moment.',
                              '画像をアップロードして、お気に入りの瞬間を共有しましょう。',
                            ),
                      textAlign: TextAlign.center,
                    ),
                    if (search.text.isNotEmpty || category.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          search.clear();
                          setState(() => category = '');
                          load(requestedPage: 1);
                        },
                        child: Text(
                          g('查看全部图片', 'Show all images', 'すべての画像を表示'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 12,
            children: [
              Text(
                g(
                  '点击图片查看大图，下载与图片信息都在预览中。',
                  'Open an image for a full preview, details and downloads.',
                  '画像を開くと、大きなプレビュー、詳細、ダウンロードを利用できます。',
                ),
                style: const TextStyle(fontSize: 11, height: 1.7),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('gallery-previous-page'),
                    tooltip: g('上一页', 'Previous page', '前のページ'),
                    onPressed: page > 1 && !loading
                        ? () => load(requestedPage: page - 1)
                        : null,
                    icon: const Icon(Icons.arrow_back, size: 17),
                  ),
                  Text('$page / $pages'),
                  IconButton(
                    key: const Key('gallery-next-page'),
                    tooltip: g('下一页', 'Next page', '次のページ'),
                    onPressed: page < pages && !loading
                        ? () => load(requestedPage: page + 1)
                        : null,
                    icon: const Icon(Icons.arrow_forward, size: 17),
                  ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _galleryDiscovery() => SiteCard(
    child: LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final searchField = TextField(
          key: const Key('gallery-search'),
          controller: search,
          maxLength: 80,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => load(requestedPage: 1),
          decoration: InputDecoration(
            counterText: '',
            hintText: g(
              '搜索名称、标签或描述…',
              'Search names, tags or descriptions…',
              '名前、タグ、説明を検索…',
            ),
            prefixIcon: const Icon(Icons.search, size: 17),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (search.text.isNotEmpty)
                  IconButton(
                    tooltip: g('清空搜索', 'Clear search', '検索をクリア'),
                    onPressed: () {
                      search.clear();
                      load(requestedPage: 1);
                    },
                    icon: const Icon(Icons.close, size: 15),
                  ),
                IconButton(
                  key: const Key('gallery-search-submit'),
                  tooltip: g('搜索', 'Search', '検索'),
                  onPressed: () => load(requestedPage: 1),
                  icon: const Icon(Icons.arrow_forward, size: 17),
                ),
              ],
            ),
          ),
        );
        final random = OutlinedButton.icon(
          key: const Key('gallery-random'),
          onPressed: randomLoading ? null : browseRandom,
          icon: const Icon(Icons.explore_outlined, size: 17),
          label: Text(
            randomLoading
                ? g('寻找中…', 'Finding…', '検索中…')
                : g('随机看看', 'Surprise me', 'ランダムに見る'),
          ),
        );
        final title = Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              manage
                  ? g('管理图片', 'Manage images', '画像を管理')
                  : g('发现图片', 'Discover images', '画像を探す'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            Text(
              loading
                  ? g('读取中…', 'Loading…', '読み込み中…')
                  : g('共 $total 张图片', '$total images', '$total 枚の画像'),
              style: const TextStyle(fontSize: 11),
            ),
          ],
        );
        final filters = Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in [
              ('', g('全部图片', 'All images', 'すべて')),
              ('wallpaper', g('壁纸', 'Wallpapers', '壁紙')),
              ('screenshot', g('截图', 'Screenshots', 'スクリーンショット')),
              ('character', g('角色', 'Characters', 'キャラクター')),
            ])
              ChoiceChip(
                key: ValueKey('gallery-filter-${entry.$1}'),
                label: Text(entry.$2),
                selected: category == entry.$1,
                onSelected: (_) {
                  setState(() => category = entry.$1);
                  load(requestedPage: 1);
                },
              ),
            PopupMenuButton<String>(
              key: const Key('gallery-tags'),
              tooltip: g('更多标签', 'More tags', 'ほかのタグ'),
              onSelected: (value) {
                search.text = value;
                setState(() => category = '');
                load(requestedPage: 1);
              },
              itemBuilder: (_) => [
                for (final tag
                    in (SiteLocaleScope.maybeOf(context)?.language == 'en'
                        ? ['Yachiyo', 'Moon', 'Night', 'Stars']
                        : ['八千代', '月读', '星空', '夜景']))
                  PopupMenuItem(value: tag, child: Text(tag)),
              ],
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(g('更多标签', 'More tags', 'ほかのタグ'))),
                    const Icon(Icons.expand_more, size: 15),
                  ],
                ),
              ),
            ),
          ],
        );
        final views = Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: (180 * scale).clamp(0, box.maxWidth),
              child: DropdownButton<String>(
                isExpanded: true,
                key: const Key('gallery-sort'),
                value: sort,
                itemHeight: null,
                underline: const SizedBox(),
                items: [
                  DropdownMenuItem(
                    value: 'latest',
                    child: Text(g('最新上传', 'Newest first', '新しい順')),
                  ),
                  DropdownMenuItem(
                    value: 'oldest',
                    child: Text(g('最早上传', 'Oldest first', '古い順')),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => sort = value);
                  load(requestedPage: 1);
                },
              ),
            ),
            if (box.maxWidth >= 960 * scale)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final columns in [4, 3])
                    IconButton(
                      key: ValueKey('gallery-columns-$columns'),
                      isSelected: galleryColumns == columns,
                      tooltip: columns == 4
                          ? g(
                              '紧凑四列视图',
                              'Compact four column view',
                              'コンパクトな 4 列表示',
                            )
                          : g(
                              '宽松三列视图',
                              'Spacious three column view',
                              'ゆったりした 3 列表示',
                            ),
                      onPressed: () => setState(() => galleryColumns = columns),
                      icon: Icon(
                        columns == 4 ? Icons.grid_view : Icons.image_outlined,
                        size: 18,
                      ),
                    ),
                ],
              ),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (box.maxWidth >= 900 * scale)
              Row(
                children: [
                  Expanded(child: title),
                  const SizedBox(width: 18),
                  SizedBox(width: 320, child: searchField),
                  if (!manage) ...[const SizedBox(width: 12), random],
                ],
              )
            else ...[
              title,
              const SizedBox(height: 14),
              searchField,
              if (!manage) ...[
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerRight, child: random),
              ],
            ],
            const SizedBox(height: 18),
            if (box.maxWidth >= 1050 * scale)
              Row(
                children: [
                  Expanded(child: filters),
                  const SizedBox(width: 16),
                  views,
                ],
              )
            else ...[
              filters,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerRight, child: views),
            ],
          ],
        );
      },
    ),
  );

  Widget _galleryCard(Map<String, dynamic> asset, {required bool showLevel}) {
    final tags = galleryTags(asset),
        name = '${asset['owner_username'] ?? ''}'.trim();
    final colors = Theme.of(context).colorScheme;
    final date = dateText(asset['created_at']);
    return RepaintBoundary(
      child: Material(
        key: ValueKey('gallery-card-${asset['id']}'),
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: ValueKey('gallery-preview-${asset['id']}'),
              onTap: () => preview(asset),
              child: Semantics(
                button: true,
                label:
                    '${g('查看大图', 'View image', '画像を表示')}：${galleryImageTitle(asset)}',
                child: AspectRatio(
                  aspectRatio: 1.6,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NativeGalleryImage(
                        asset: asset,
                        site: c.settings.siteUrl,
                        cookie: c.site.cookie,
                        height: null,
                        fit: BoxFit.cover,
                      ),
                      if (tags.isNotEmpty)
                        Positioned(
                          left: 10,
                          top: 10,
                          right: 10,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                child: Text(
                                  tags.first,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    galleryImageTitle(asset),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: name.isEmpty
                              ? null
                              : () => widget.onGo(
                                  '/users/${Uri.encodeComponent(name)}',
                                ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                NativeGalleryAvatar(
                                  asset: asset,
                                  site: c.settings.siteUrl,
                                  cookie: c.site.cookie,
                                  size: 22,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    name.isEmpty
                                        ? g('站点归档', 'Site archive', 'サイトアーカイブ')
                                        : galleryUploaderName(asset),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                                if (showLevel &&
                                    '${asset['owner_id'] ?? ''}'.isNotEmpty)
                                  NativeUserLevelBadge(
                                    level: userLevels.level(asset['owner_id']),
                                    compact: true,
                                    showTitle: false,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        date.length >= 10
                            ? date.substring(5, 10).replaceAll('-', ' / ')
                            : date,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ),
                  if (manage) ...[
                    const Divider(height: 24),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => copy(asset),
                          icon: const Icon(Icons.copy, size: 15),
                          label: const Text('Markdown'),
                        ),
                        if (admin || '${asset['owner_id']}' == c.account?.id)
                          TextButton.icon(
                            onPressed: () => delete(asset),
                            icon: const Icon(Icons.delete_outline, size: 15),
                            label: Text(g('删除', 'Delete', '削除')),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _libraryBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SitePageHero(
        title: widget.gallery
            ? (manage ? (admin ? '管理全部图库图片' : '管理我的图库图片') : '图库')
            : '附件库',
        kicker: widget.gallery ? 'GALLERY' : 'ASSET LIBRARY',
        subtitle: widget.gallery
            ? '收藏插画、截图、设定图与站点视觉记录。'
            : '图片、音视频、PDF、TXT 与 Markdown。单文件最大 100 MB，重新选择同一文件可继续上传。',
      ),
      if (private && !authed)
        SiteCard(
          child: Column(
            children: [
              const SiteText('登录后管理自己上传的附件'),
              TextButton(
                onPressed: () => showSiteLogin(context, c),
                child: const SiteText('去登录'),
              ),
            ],
          ),
        )
      else ...[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: search,
                onSubmitted: (_) => load(requestedPage: 1),
                decoration: InputDecoration(
                  hintText: siteTranslate(
                    context,
                    widget.gallery ? '搜索图库' : '搜索附件',
                  ),
                  suffixIcon: IconButton(
                    onPressed: () => load(requestedPage: 1),
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
            ),
            if (widget.gallery)
              OutlinedButton(
                onPressed: () =>
                    widget.onGo(manage ? '/gallery' : '/gallery/manage'),
                child: SiteText(manage ? '浏览图库' : '图库管理'),
              ),
            if (!widget.gallery || manage)
              FilledButton(
                onPressed: uploading ? null : chooseAndUpload,
                child: const SiteText('上传文件'),
              ),
            if (!widget.gallery)
              OutlinedButton(
                onPressed: () => widget.onGo('/editor'),
                child: const SiteText('写文章'),
              ),
          ],
        ),
        if (!widget.gallery)
          Wrap(
            spacing: 8,
            children: [
              for (final entry in {
                'all': '全部',
                'image': '图片',
                'video': '视频',
                'audio': '音频',
                'document': '文档',
                'file': '文件',
              }.entries)
                if (!widget.imageOnly || entry.key == 'image')
                  ChoiceChip(
                    label: SiteText(entry.value),
                    selected: type == entry.key,
                    onSelected: (_) {
                      setState(() => type = entry.key);
                      load(requestedPage: 1);
                    },
                  ),
              if (admin)
                ChoiceChip(
                  label: const SiteText('全部用户'),
                  selected: scope == 'all',
                  onSelected: (selected) {
                    setState(() => scope = selected ? 'all' : 'mine');
                    load(requestedPage: 1);
                  },
                ),
            ],
          ),
        if (!widget.gallery)
          DropdownButton<String>(
            isExpanded: true,
            itemHeight: null,
            value: storageMode,
            items: const [
              DropdownMenuItem(value: 'auto', child: SiteText('跟随站点默认存储')),
              DropdownMenuItem(value: 'local', child: SiteText('本地存储')),
              DropdownMenuItem(value: 'oss', child: SiteText('对象存储')),
            ],
            onChanged: uploading
                ? null
                : (value) => setState(() => storageMode = value!),
          ),
        if (uploading)
          SiteCard(
            child: Column(
              children: [
                SiteText(phase),
                LinearProgressIndicator(value: progress),
                TextButton(
                  onPressed: widget.gallery ? null : () => upload?.cancel(),
                  child: const SiteText('暂停上传'),
                ),
              ],
            ),
          ),
        if (!uploading && pending.isNotEmpty)
          SiteCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SiteText('未完成的上传保留 24 小时。重新选择同一文件可继续。'),
                for (final item in pending)
                  ListTile(
                    title: Text('${item['fileName']}'),
                    subtitle: Text('${item['received']} / ${item['size']} 字节'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: siteTranslate(context, '取消上传'),
                      onPressed: () async {
                        try {
                          await service.request(
                            'DELETE',
                            '/api/assets/uploads/${Uri.encodeComponent('${item['id']}')}',
                          );
                          await loadPending();
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        Text(
          siteTr(
            context,
            'nativeAssetPagination',
            params: {'total': total, 'page': page, 'pages': pages},
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 620
                ? 1
                : constraints.maxWidth < 980
                ? 2
                : 3;
            final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final asset in assets)
                  SizedBox(width: width, child: card(asset)),
              ],
            );
          },
        ),
        if (!loading && assets.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: SiteText(widget.gallery ? '暂时还没有匹配的图片' : '还没有匹配的附件'),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton(
              onPressed: page > 1 && !loading
                  ? () => load(requestedPage: page - 1)
                  : null,
              child: const SiteText('上一页'),
            ),
            Text('$page / $pages'),
            TextButton(
              onPressed: page < pages && !loading
                  ? () => load(requestedPage: page + 1)
                  : null,
              child: const SiteText('下一页'),
            ),
          ],
        ),
      ],
    ],
  );
}

Future<Uint8List> _galleryImage(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = (2200 / descriptor.width).clamp(0.0, 1.0).toDouble();
    final heightScale = (1800 / descriptor.height).clamp(0.0, 1.0).toDouble();
    final resize = scale < heightScale ? scale : heightScale;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * resize).round().clamp(1, 2200),
      targetHeight: (descriptor.height * resize).round().clamp(1, 1800),
    );
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      return await compute(_encodeGalleryJpeg, (
        frame.image.width,
        frame.image.height,
        data!.buffer.asUint8List(),
      ));
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Uint8List _encodeGalleryJpeg((int, int, Uint8List) pixels) => image.encodeJpg(
  image.Image.fromBytes(
    width: pixels.$1,
    height: pixels.$2,
    bytes: pixels.$3.buffer,
    numChannels: 4,
    order: image.ChannelOrder.rgba,
  ),
  quality: 86,
);
