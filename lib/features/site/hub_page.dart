import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'hub_pixel_preview.dart';
import 'login_dialog.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';
import 'site_chrome.dart';

/// Native counterpart of the website HubPage and its aggregated preview API.
class HubPage extends StatefulWidget {
  const HubPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;

  @override
  State<HubPage> createState() => _HubPageState();
}

class _HubPageState extends State<HubPage> with WidgetsBindingObserver {
  late final SiteRepository _repo;
  final _greeting = TextEditingController();
  Map<String, dynamic> _data = {}, _settings = {};
  String _scope = '', _siteUrl = '', _error = '', _notice = '', _feedback = '';
  bool _loading = true, _submitting = false, _feedbackError = false;
  int _request = 0, _draftRequest = 0;
  RoomController get c => widget.controller;
  String get _draftKey => 'hub-greeting:${_repo.scope}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repo = SiteRepository(
      api: c.site as SiteDataService,
      storage: c.storage,
      site: () => c.settings.siteUrl,
      accountId: () => c.account?.id,
    );
    _scope = _repo.scope;
    _siteUrl = c.settings.siteUrl;
    c.addListener(_accountChanged);
    _restoreGreeting();
    _load();
  }

  Future<void> _restoreGreeting() async {
    final owner = _repo.scope, ticket = ++_draftRequest;
    try {
      final value = await c.storage.draft(_draftKey);
      if (mounted && ticket == _draftRequest && owner == _repo.scope) {
        _greeting.text = value;
      }
    } catch (_) {
      // A local draft failure must not prevent public previews from loading.
    }
  }

  void _saveGreeting(String value) {
    _draftRequest++;
    unawaited(c.storage.saveDraft(_draftKey, value).catchError((_) {}));
  }

  void _accountChanged() {
    if (!mounted) return;
    if (_scope != _repo.scope || _siteUrl != c.settings.siteUrl) {
      _scope = _repo.scope;
      _siteUrl = c.settings.siteUrl;
      _request++;
      _data = {};
      _settings = {};
      _greeting.clear();
      _feedback = '';
      _submitting = false;
      _restoreGreeting();
      _load();
    }
    // Chat/workspace/voice changes are unrelated to this public preview. The
    // shell observes account details itself; only a different scope reloads it.
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _draftRequest++;
    c.removeListener(_accountChanged);
    WidgetsBinding.instance.removeObserver(this);
    _greeting.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ticket = ++_request;
    setState(() {
      _loading = true;
      _error = '';
    });
    final settings = _loadSettings(ticket);
    try {
      if (_data.isEmpty) {
        final cached = await _repo.cached('/api/hub-preview');
        if (cached != null && mounted && ticket == _request) {
          setState(() {
            _data = mapOf(cached.data);
            _notice = cached.notice;
          });
        }
      }
      final result = await _repo
          .read('/api/hub-preview')
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw const ApiFailure('内容读取超时，请重试'),
          );
      if (!mounted || ticket != _request) return;
      if (result.data is! Map) throw const ApiFailure('中枢响应缺少预览数据');
      setState(() {
        _data = mapOf(result.data);
        _notice = result.notice;
      });
    } catch (e) {
      if (mounted && ticket == _request) setState(() => _error = '$e');
    } finally {
      if (mounted && ticket == _request) setState(() => _loading = false);
    }
    await settings;
  }

  Future<void> _loadSettings(int ticket) async {
    try {
      final result = await _repo
          .read('/api/settings')
          .timeout(const Duration(seconds: 8));
      if (mounted && ticket == _request) {
        setState(() => _settings = mapOf(result.data));
      }
    } catch (_) {
      if (mounted && ticket == _request && _settings.isEmpty) {
        setState(() {
          _settings = {'visitPopupContent': '弹窗内容暂时无法读取。'};
        });
      }
    }
  }

  Future<void> _login() async {
    if (c.account != null && !c.sessionExpired) {
      widget.onGo('/user');
      return;
    }
    await showSiteLogin(context, c);
  }

  Future<void> _submitGreeting() async {
    if (_submitting) return;
    final content = _greeting.text.trim();
    if (content.isEmpty) {
      setState(() {
        _feedback = '留言不能为空';
        _feedbackError = true;
      });
      return;
    }
    if (c.account == null || c.sessionExpired) {
      await _login();
      return;
    }
    final owner = _repo.scope;
    setState(() {
      _submitting = true;
      _feedback = '';
    });
    try {
      final result = await _repo.write('POST', '/api/messages', {
        'content': content,
      });
      if (!mounted || owner != _repo.scope) return;
      _greeting.clear();
      _saveGreeting('');
      setState(() {
        final message = mapOf(result['data']);
        if (message['id'] != null) {
          _data['messages'] = [
            message,
            ...rowsOf(_data['messages'])
                .where((item) => item['id'] != message['id']),
          ];
          final stats = mapOf(_data['stats']);
          if (stats.isNotEmpty) {
            stats['messages'] = (stats['messages'] as num? ?? 0) + 1;
            _data['stats'] = stats;
          }
        }
        _feedback = '已发布';
        _feedbackError = false;
      });
      await _load();
    } catch (e) {
      if (mounted && owner == _repo.scope) {
        setState(() {
          _feedback = '$e';
          _feedbackError = true;
        });
      }
    } finally {
      if (mounted && owner == _repo.scope) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '中枢',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RepaintBoundary(child: _hero()),
        const SizedBox(height: 20),
        _announcement(),
        const SizedBox(height: 26),
        _latest(),
        const SizedBox(height: 20),
        if (_notice.isNotEmpty) _status(_notice),
        if (_error.isNotEmpty) _status(_error, error: true),
        if (_loading && _data.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_data.isNotEmpty) ...[
          RepaintBoundary(child: _scenes()),
          const SizedBox(height: 20),
          RepaintBoundary(child: _plaza()),
        ],
        RepaintBoundary(child: _stats()),
      ],
    ),
  );

  Widget _hero() => LayoutBuilder(
    builder: (context, box) {
      final p = RoomStyle(context);
      final mobile = box.maxWidth <= 600, tablet = box.maxWidth < 1100;
      Widget artwork() => Image.asset(
        'assets/images/sakura/yachiyo-lake.webp',
        cacheWidth: (box.maxWidth * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 1672),
        fit: BoxFit.cover,
        alignment: mobile ? const Alignment(.3, 0) : const Alignment(0, -.24),
        color: p.dark ? Colors.black.withValues(alpha: .22) : null,
        colorBlendMode: BlendMode.darken,
        semanticLabel: '月见八千代',
      );
      final copy = Padding(
        padding: EdgeInsets.fromLTRB(
          mobile ? 22 : 40,
          mobile ? 26 : 36,
          mobile ? 22 : 36,
          mobile ? 0 : 36,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SiteText(
              'TSUKUYOMI · A MOONLIT COMMUNITY',
              style: TextStyle(
                fontSize: 10,
                color: p.muted,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 18),
            SiteText(
              '与你相遇，在月光之下',
              style: TextStyle(color: p.ink, fontSize: mobile ? 14 : 17),
            ),
            const SizedBox(height: 8),
            SiteText(
              '月读空间',
              style: TextStyle(
                fontFamily: RoomStyle.serif,
                fontSize: mobile
                    ? 34
                    : tablet
                    ? 48
                    : 68,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 9),
            SiteText(
              'Tsukuyomi Space',
              translate: false,
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 2.6,
                color: p.muted,
              ),
            ),
            SizedBox(height: mobile ? 16 : 24),
            SiteText(
              '给日常留一点月光。与八千代聊天，读故事、看创作，遇见同频的人。',
              style: TextStyle(
                fontSize: mobile ? 13 : 18,
                height: 1.8,
                color: p.muted,
              ),
            ),
            SizedBox(height: mobile ? 20 : 30),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => widget.onGo('/room'),
                  icon: const Icon(CupertinoIcons.moon, size: 17),
                  label: const SiteText('进入私人居所'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(backgroundColor: p.surface),
                  onPressed: () => widget.onGo('/stage'),
                  icon: const Icon(Icons.arrow_forward, size: 17),
                  label: const SiteText('发现创作'),
                ),
              ],
            ),
          ],
        ),
      );
      return Container(
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: p.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: mobile
            ? Column(
                children: [
                  copy,
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 245,
                    width: double.infinity,
                    child: artwork(),
                  ),
                ],
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 416),
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      bottom: 0,
                      right: 0,
                      width: box.maxWidth * (tablet ? .54 : .64),
                      child: IgnorePointer(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [Colors.transparent, Colors.black],
                            stops: [0, .44],
                          ).createShader(bounds),
                          child: artwork(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: box.maxWidth * (tablet ? .46 : .54),
                      child: copy,
                    ),
                  ],
                ),
              ),
      );
    },
  );

  Widget _announcement() => Material(
    color: RoomStyle(context).surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: RoomStyle(context).line),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(CupertinoIcons.bell, size: 18),
        title: const SiteText('站内公告', style: TextStyle(fontSize: 13)),
        subtitle: Text(_setting('visitPopupTitle', '欢迎来到月读空间')),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 20),
              child: SelectableText(
                _setting('visitPopupContent', '首次访问弹窗尚未配置内容。'),
                style: const TextStyle(height: 1.9),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  String _setting(String key, String fallback) {
    final value = textOf(_settings, key).trim();
    return value.isEmpty ? fallback : value;
  }

  Widget _latest() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SiteText('月下新鲜事', style: TextStyle(fontSize: 25)),
      const SizedBox(height: 7),
      SiteText(
        '读一篇文章，发现一份创作，留下今天的问候。',
        style: TextStyle(fontSize: 13, color: RoomStyle(context).muted),
      ),
    ],
  );

  Widget _status(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SiteCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(
            error ? Icons.error_outline : Icons.cloud_off_outlined,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
          TextButton(onPressed: _load, child: const SiteText('重试')),
        ],
      ),
    ),
  );

  Widget _scenes() => LayoutBuilder(
    builder: (context, box) {
      final article = mapOf(_data['article']);
      final gallery = mapOf(_data['gallery']);
      final pixel = mapOf(_data['pixel']);
      final columns = box.maxWidth > 820
          ? 3
          : box.maxWidth > 600
          ? 2
          : 1;
      final width = (box.maxWidth - 20 * (columns - 1)) / columns;
      return Wrap(
        spacing: 20,
        runSpacing: 20,
        children: [
          SizedBox(
            width: columns == 2 ? box.maxWidth : width,
            child: _scene(
              path: '/stage',
              metadata: article,
              title: textOf(article, 'title', '主舞台'),
              description: plainText(textOf(article, 'excerpt', '记录、创作、知识')),
              label: '主舞台',
              code: textOf(article, 'category', 'Stage'),
              icon: CupertinoIcons.book,
              image: textOf(
                article,
                'cover_image',
                textOf(article, 'cover_image_url'),
              ),
            ),
          ),
          SizedBox(
            width: width,
            child: _scene(
              path: '/gallery',
              metadata: gallery,
              title: gallery.isEmpty ? '月影图库' : '最新图库影像',
              description: gallery.isEmpty
                  ? '公开影像、插画与站点视觉记录'
                  : '发布于 ${dateText(gallery['created_at'] ?? gallery['updated_at'])}',
              label: '月影图库',
              code: 'Gallery',
              icon: CupertinoIcons.photo,
              image: textOf(
                gallery,
                'url',
                textOf(gallery, 'access_url', textOf(gallery, 'display_url')),
              ),
            ),
          ),
          SizedBox(
            width: width,
            child: _scene(
              path: '/pixel',
              metadata: pixel,
              title: textOf(pixel, 'title', '月光像素工坊'),
              description: pixel.isEmpty
                  ? '绘制、发布、点赞月光像素画'
                  : '${userDisplayName(pixel, prefix: 'author')} 发布于 ${dateText(pixel['created_at'] ?? pixel['updated_at'])}',
              label: pixel.isEmpty ? '月光像素工坊' : '最新像素画',
              code: pixel.isEmpty
                  ? 'Arena'
                  : '${pixel['width'] ?? 96}×${pixel['height'] ?? 54}',
              icon: CupertinoIcons.paintbrush,
              artwork: pixel.isEmpty ? null : pixel,
            ),
          ),
        ],
      );
    },
  );

  Widget _scene({
    required String path,
    required String title,
    required String description,
    required String label,
    required String code,
    required IconData icon,
    String image = '',
    Map<String, dynamic>? artwork,
    Map<String, dynamic> metadata = const {},
  }) => LayoutBuilder(
    builder: (context, box) {
      final p = RoomStyle(context);
      final mobile = MediaQuery.sizeOf(context).width <= 600;
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final author = userDisplayName(metadata, prefix: 'author', fallback: '');
      final date = dateText(metadata['created_at'] ?? metadata['updated_at']);
      Widget media() {
        final fallback = Image.asset(
          switch (path) {
            '/stage' => 'assets/images/sakura/moonlit-shrine.webp',
            '/gallery' => 'assets/images/sakura/yachiyo-portrait.webp',
            _ => 'assets/images/sakura/sakura-station.webp',
          },
          fit: BoxFit.cover,
          cacheHeight: (160 * scale * MediaQuery.devicePixelRatioOf(context))
              .ceil()
              .clamp(1, 1600),
        );
        Widget imageWidget = fallback;
        if (artwork != null) {
          imageWidget = HubPixelPreview(artwork: artwork);
        } else if (image.isNotEmpty) {
          final target = endpointUri(c.settings.siteUrl).resolve(image);
          if (['https', 'http'].contains(target.scheme) &&
              target.userInfo.isEmpty) {
            imageWidget = Image.network(
              '$target',
              fit: BoxFit.cover,
              cacheHeight:
                  (160 * scale * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, 1600),
              errorBuilder: (_, _, _) => fallback,
            );
          }
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              imageWidget,
              if (!mobile)
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 18, color: Colors.white),
                  ),
                ),
            ],
          ),
        );
      }

      Widget details() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (mobile)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                code,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10, color: p.muted),
              ),
            ),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: RoomStyle.serif,
              fontSize: mobile ? 17 : 19,
              fontWeight: FontWeight.w600,
              height: 1.45,
              color: p.ink,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            maxLines: mobile ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: mobile ? 12 : 15,
              color: p.muted,
              height: 1.65,
            ),
          ),
          if (author.isNotEmpty || date.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                if (author.isNotEmpty)
                  Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: p.muted),
                  ),
                if (date.isNotEmpty)
                  Text(
                    date,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: p.muted),
                  ),
              ],
            ),
          ],
        ],
      );
      return Semantics(
        label: '$label：$title',
        button: true,
        child: Material(
          color: p.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: p.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => widget.onGo(path),
            child: Padding(
              padding: EdgeInsets.all(mobile ? 10 : 12),
              child: mobile
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: box.maxWidth * .30,
                          height: 122 * scale,
                          child: media(),
                        ),
                        const SizedBox(width: 13),
                        Expanded(child: details()),
                      ],
                    )
                  : ConstrainedBox(
                      constraints: BoxConstraints(minHeight: 296 * scale),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(height: 160, child: media()),
                          const SizedBox(height: 12),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: details(),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      );
    },
  );

  Widget _plaza() => SiteCard(
    child: LayoutBuilder(
      builder: (context, box) {
        final p = RoomStyle(context);
        final messages = rowsOf(_data['messages']).take(3).toList();
        final wide = box.maxWidth >= 700;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(CupertinoIcons.chat_bubble_2, color: p.accent),
                const SiteText('月读广场', style: TextStyle(fontSize: 21)),
                TextButton(
                  onPressed: () => widget.onGo('/plaza'),
                  child: const SiteText('逛逛广场'),
                ),
              ],
            ),
            SiteText(
              '分享此刻，也遇见同频的人。',
              style: TextStyle(color: p.muted, fontSize: 13),
            ),
            const SizedBox(height: 22),
            if (messages.isEmpty) const SiteText('还没有留言，写下第一句问候。'),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: [
                for (final message in messages)
                  SizedBox(
                    width: wide ? (box.maxWidth - 28) / 3 : box.maxWidth,
                    child: InkWell(
                      onTap: () => widget.onGo('/plaza'),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        padding: const EdgeInsets.all(17),
                        decoration: BoxDecoration(
                          color: p.background,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: p.line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                SiteAvatar(
                                  value: textOf(message, 'avatar'),
                                  name: userDisplayName(
                                    message,
                                    prefix: 'author',
                                  ),
                                  site: c.settings.siteUrl,
                                  size: 28,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Text(
                                    userDisplayName(message, prefix: 'author'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              textOf(message, 'content'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.75,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Divider(color: p.line),
            const SizedBox(height: 12),
            const SiteText('留一句问候', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            TextField(
              key: const Key('hub-greeting'),
              controller: _greeting,
              enabled: !_submitting,
              onChanged: _saveGreeting,
              onSubmitted: (_) => _submitGreeting(),
              decoration: const InputDecoration(
                hintText: '今天有什么想和大家分享的？',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                key: const Key('hub-send'),
                onPressed: _submitting ? null : _submitGreeting,
                icon: const Icon(CupertinoIcons.paperplane, size: 15),
                label: Text(_submitting ? '发送中' : '发送'),
              ),
            ),
            if (_feedback.isNotEmpty)
              Text(
                _feedback,
                key: const Key('hub-feedback'),
                style: TextStyle(
                  color: _feedbackError
                      ? Theme.of(context).colorScheme.error
                      : p.accent,
                ),
              ),
          ],
        );
      },
    ),
  );

  Widget _stats() => LayoutBuilder(
    builder: (context, box) {
      final stats = mapOf(_data['stats']);
      final visits = SiteChromeScope.maybeOf(context)?.publicStats;
      if (visits != null) {
        for (final key in ['todayViews', 'totalViews']) {
          if (visits.containsKey(key)) stats[key] = visits[key];
        }
      }
      final uptime = (stats['uptime'] as num? ?? 0).toInt();
      final days = uptime ~/ 86400, hours = uptime % 86400 ~/ 3600;
      final values = {
        '今日访问': '${stats['todayViews'] ?? 0}',
        '总访问': '${stats['totalViews'] ?? 0}',
        '注册用户': '${stats['users'] ?? 0}',
        '站内文章': '${stats['articles'] ?? 0}',
        '广场留言': '${stats['messages'] ?? 0}',
        '运行时间': uptime == 0
            ? '--'
            : days > 0
            ? '$days天$hours时'
            : '${hours > 0 ? hours : 1}小时',
      };
      final columns = box.maxWidth >= 700 ? 6 : 3;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            SiteText(
              '一起留下的足迹',
              style: TextStyle(fontSize: 14, color: RoomStyle(context).muted),
            ),
            const SizedBox(height: 18),
            Wrap(
              runSpacing: 24,
              children: [
                for (final entry in values.entries)
                  SizedBox(
                    width: box.maxWidth / columns,
                    child: Column(
                      children: [
                        Text(entry.value, style: const TextStyle(fontSize: 22)),
                        const SizedBox(height: 4),
                        Text(
                          entry.key,
                          style: TextStyle(
                            fontSize: 11,
                            color: RoomStyle(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (textOf(_settings, 'beianText').isNotEmpty)
              TextButton(
                onPressed: () => openSiteLink(
                  c.settings.siteUrl,
                  _setting('beianUrl', 'https://beian.miit.gov.cn/'),
                ),
                child: Text(textOf(_settings, 'beianText')),
              ),
            if (textOf(_settings, 'mpsBeianText').isNotEmpty)
              TextButton(
                onPressed: () => openSiteLink(
                  c.settings.siteUrl,
                  _setting('mpsBeianUrl', 'https://beian.mps.gov.cn/'),
                ),
                child: Text(textOf(_settings, 'mpsBeianText')),
              ),
          ],
        ),
      );
    },
  );
}
