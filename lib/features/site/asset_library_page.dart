import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import 'content_page_shell.dart';
import 'native_site_shell.dart';
import 'login_dialog.dart';
import 'native_asset_service.dart';
import 'native_gallery_details.dart';
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
  Map<String, dynamic>? latest, featured;
  bool loading = true, uploading = false, admin = false;
  String error = '',
      notice = '',
      type = 'all',
      storageMode = 'auto',
      scope = 'mine',
      owner = '',
      phase = '';
  double? progress;
  int page = 1,
      pages = 1,
      total = 0,
      requestId = 0,
      featuredRequest = 0,
      latestRequest = 0;
  Timer? rotation;
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
    type = widget.imageOnly ? 'image' : 'all';
    c.addListener(accountChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) load();
    });
    rotation = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted &&
          widget.gallery &&
          !manage &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          ModalRoute.of(context)?.isCurrent == true) {
        loadFeatured();
      }
    });
  }

  void accountChanged() {
    if (!mounted) return;
    if (owner != service.scope) {
      owner = service.scope;
      requestId++;
      featuredRequest++;
      latestRequest++;
      upload?.cancel();
      uploading = false;
      upload = null;
      assets = [];
      latest = null;
      featured = null;
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
    featuredRequest++;
    latestRequest++;
    upload?.cancel();
    rotation?.cancel();
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
      if (widget.gallery && !manage) {
        await Future.wait([loadFeatured(), loadLatest()]);
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

  Future<void> loadFeatured() async {
    final current = service.scope, ticket = ++featuredRequest;
    try {
      final doc = await service.request(
        'GET',
        '/api/assets/gallery/public?limit=1&random=1',
      );
      if (mounted && current == service.scope && ticket == featuredRequest) {
        setState(
          () => featured = rowsOf(mapOf(doc['data'])['assets']).firstOrNull,
        );
        if (featured != null) unawaited(hydrateLevels([featured!]));
      }
    } catch (_) {}
  }

  Future<void> loadLatest() async {
    final current = service.scope, ticket = ++latestRequest;
    try {
      final doc = await service.request(
        'GET',
        '/api/assets/gallery/public?limit=1',
      );
      if (mounted && current == service.scope && ticket == latestRequest) {
        setState(
          () => latest = rowsOf(mapOf(doc['data'])['assets']).firstOrNull,
        );
        if (latest != null) unawaited(hydrateLevels([latest!]));
      }
    } catch (_) {}
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

  Future<void> copy(Map<String, dynamic> asset) async {
    final current = service.scope;
    try {
      await Clipboard.setData(ClipboardData(text: nativeAssetMarkdown(asset)));
      if (mounted && current == service.scope) {
        setState(() => notice = 'Markdown 已复制，可以直接粘贴到文章正文');
      }
    } catch (_) {
      if (mounted && current == service.scope) {
        setState(() => error = '复制失败，请重试');
      }
    }
  }

  Future<void> preview(Map<String, dynamic> asset) => showDialog<void>(
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
    child: LayoutBuilder(
      builder: (context, box) {
        if (!widget.gallery ||
            manage ||
            box.maxWidth <
                1000 * (MediaQuery.textScalerOf(context).scale(14) / 14)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _libraryBody(),
              if (widget.gallery && !manage) _gallerySidebar(),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _libraryBody()),
            const SizedBox(width: 20),
            SizedBox(width: 280, child: _gallerySidebar()),
          ],
        );
      },
    ),
  );

  void _filterGallery(String value) {
    search.text = value;
    load(requestedPage: 1);
  }

  Widget _gallerySidebar() => NativeSiteSection(
    title: '图库概览',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 16,
          children: [
            for (final item in [('当前图片', total), ('本页展示', assets.length)])
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SiteText(item.$1),
                  Text(
                    '${item.$2}',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
          ],
        ),
        const Divider(height: 32),
        const SiteText('快速筛选', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in [
              ('全部图片', ''),
              ('壁纸', 'wallpaper'),
              ('截图', 'screenshot'),
            ])
              OutlinedButton(
                onPressed: () => _filterGallery(item.$2),
                child: SiteText(item.$1),
              ),
          ],
        ),
        const Divider(height: 32),
        const SiteText('图库上传入口', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        const SiteText(
          '登录后进入「图库管理」页面上传图片；上传到图库的公开图片会显示在当前页面。',
          style: TextStyle(height: 1.7),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => widget.onGo(
            authed ? '/gallery/manage' : '/login?redirect=%2Fgallery%2Fmanage',
          ),
          child: SiteText(authed ? '进入图库管理' : '登录后上传'),
        ),
        const Divider(height: 32),
        const SiteText('常用标签', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final label in ['月读', '星空', '夜景', '角色'])
              ActionChip(
                label: SiteText(label),
                onPressed: () => _filterGallery(label),
              ),
          ],
        ),
      ],
    ),
  );
  Widget _libraryBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SitePageHero(
        title: widget.gallery
            ? (manage ? (admin ? '管理全部图库图片' : '管理我的图库图片') : '图库')
            : '附件库',
        kicker: widget.gallery ? 'GALLERY' : 'ASSET LIBRARY',
        background: widget.gallery
            ? (latest == null
                  ? Image.asset(
                      'assets/images/tsukuyomi-bg.webp',
                      fit: BoxFit.cover,
                      cacheWidth: 1600,
                    )
                  : nativeSiteImage(
                      c.settings.siteUrl,
                      galleryImageUrls(
                            latest!,
                            c.settings.siteUrl,
                            preview: false,
                          ).lastOrNull ??
                          '',
                      width: double.infinity,
                    ))
            : null,
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
        if (widget.gallery && !manage && (latest != null || featured != null))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                if (latest != null)
                  SizedBox(
                    width: min(420, MediaQuery.sizeOf(context).width - 28),
                    child: Column(
                      children: [const SiteText('最新影像'), card(latest!)],
                    ),
                  ),
                if (featured != null)
                  SizedBox(
                    width: min(420, MediaQuery.sizeOf(context).width - 28),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 420),
                      child: Column(
                        key: ValueKey(featured!['id']),
                        children: [
                          const SiteText('随机放映 · 每 30 秒轮换'),
                          card(featured!),
                        ],
                      ),
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
