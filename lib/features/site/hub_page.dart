import 'hub_hero.dart';
import '../../core/season_theme.dart';
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

import 'native_site_shell.dart';
import 'site_widgets.dart';

import 'site_chrome.dart';
import 'site_notice.dart';

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
  String _scope = '', _siteUrl = '', _error = '', _notice = '';
  final _journal = GlobalKey();
  List<Map<String, dynamic>> _articles = [];
  bool _loading = true;
  int _request = 0;
  RoomController get c => widget.controller;

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

    _load();
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
      _articles = [];

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
    final secondary = Future.wait([
      _loadSettings(ticket),
      _loadArticles(ticket),
    ]);
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
    await secondary;
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

  Future<void> _loadArticles(int ticket) async {
    try {
      final doc = await _repo.read('/api/articles?page=1&limit=6&sort=latest');
      if (mounted && ticket == _request) {
        setState(() => _articles = rowsOf(doc.data));
      }
    } catch (_) {
      // The featured story remains available through the independent preview.
    }
  }

  Future<void> _enter(String value) async {
    final text = value.trim(), owner = c.scope;
    if (text.isNotEmpty) {
      if (c.loading || c.busy || c.generating) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: SiteText('房间正忙，请稍后重试')));
        return;
      }
      try {
        await c.saveComposerDraft(text, notify: true);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: SiteText('草稿保存失败，请重试')));
        }
        return;
      }
    }
    if (mounted && c.scope == owner) widget.onGo('/room');
  }

  String tr(String zh, String en, String ja) =>
      switch (SiteLocaleScope.maybeOf(context)?.language) {
        'en' => en,
        'ja' => ja,
        _ => zh,
      };
  String articlePath(Map article) {
    if (article['id'] == null) return '/stage';
    final slug = textOf(article, 'slug');
    return '/articles/${Uri.encodeComponent('${article['id']}')}${slug.isEmpty ? '' : '/${Uri.encodeComponent(slug)}'}';
  }

  @override
  Widget build(BuildContext context) {
    final featured = mapOf(_data['article']).isNotEmpty
        ? mapOf(_data['article'])
        : _articles.firstOrNull ?? {};
    return NativeSiteShell(
      controller: c,
      title: '中枢',
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      onRefresh: _load,
      fullBleed: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RepaintBoundary(
            child: HubHero(
              input: _greeting,
              onEnter: _enter,
              onDiscover: () {
                final target = _journal.currentContext;
                if (target != null) {
                  Scrollable.ensureVisible(
                    target,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 300),
                    alignment: .12,
                  );
                }
              },
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1360),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MediaQuery.sizeOf(context).width > 600 ? 48 : 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (announcementContent(_settings).isNotEmpty)
                      _announcement(),
                    SizedBox(key: _journal, height: 40),
                    _heading(
                      '01 — UNDER THE MOON',
                      tr('月下新鲜事', 'Under the moon', '月の下の新着'),
                      tr(
                        '把值得记录的日常，变成值得阅读的故事。',
                        'Everyday moments, made into stories worth keeping.',
                        '日々の記録を、読みたい物語に。',
                      ),
                      tr('全部文章', 'All stories', '記事一覧'),
                      '/stage',
                    ),
                    if (_loading && _data.isEmpty)
                      const LinearProgressIndicator(),
                    if (_error.isNotEmpty) _status(_error, error: true),
                    if (_notice.isNotEmpty) _status(_notice),
                    _stories(featured),
                    _heading(
                      '02 — WANDER A LITTLE',
                      tr('随心逛逛', 'Follow your curiosity', '気ままに歩こう'),
                      tr(
                        '喜欢的事，都能在这里找到一席之地。',
                        'A little space for everything you love.',
                        '好きなことが見つかる場所。',
                      ),
                    ),
                    _places(),
                    _heading(
                      '03 — SMALL MOMENTS, SHARED',
                      tr('月光下的声音', 'Meet under the moon', '月明かりの下で'),
                      tr(
                        '今天的小事、想分享的心情，总有人愿意听。',
                        'Small moments, little thoughts, and someone who’s here to listen.',
                        '今日の小さな出来事を分かち合おう。',
                      ),
                      tr('去广场坐坐', 'Visit the plaza', '広場へ'),
                      '/plaza',
                    ),
                    for (final m in rowsOf(_data['messages']).take(3))
                      ListTile(
                        onTap: () => widget.onGo('/plaza'),
                        leading: SiteAvatar(
                          value: textOf(m, 'avatar'),
                          name: userDisplayName(m, prefix: 'author'),
                          site: c.settings.siteUrl,
                        ),
                        title: Text(userDisplayName(m, prefix: 'author')),
                        subtitle: Text(
                          textOf(m, 'content'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(dateText(m['created_at'])),
                      ),
                    if (rowsOf(_data['messages']).isEmpty)
                      Text(
                        tr(
                          '安静的广场，等你留下第一句问候。',
                          'A quiet plaza, waiting for your first hello.',
                          '静かな広場は、あなたの挨拶を待っています。',
                        ),
                      ),
                    const SizedBox(height: 36),
                    InkWell(
                      onTap: () => widget.onGo('/drift'),
                      child: Container(
                        key: const Key('hub-letter'),
                        padding: const EdgeInsets.all(32),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          image: const DecorationImage(
                            image: AssetImage(
                              'assets/images/drift/lantern/lake-wide.webp',
                            ),
                            fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(
                              Colors.black54,
                              BlendMode.darken,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr(
                                '写给远方的某个人',
                                'A LETTER TO SOMEONE, SOMEWHERE',
                                '遠くの誰かへの手紙',
                              ),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr(
                                '把心事，交给星海。',
                                'Let a little thought drift away.',
                                '思いを星の海へ。',
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontFamily: RoomStyle.serif,
                              ),
                            ),
                            Text(
                              tr(
                                '写一封信，让月光带它去遇见一个陌生人。',
                                'Write a letter. Let the moon find someone to read it.',
                                '手紙を月明かりに託そう。',
                              ),
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const SiteBeianLinks(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(
    String eyebrow,
    String title,
    String description, [
    String? label,
    String? path,
  ]) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(eyebrow, style: const TextStyle(fontSize: 11, letterSpacing: 1.6)),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 20,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontFamily: RoomStyle.serif,
                fontSize: 30,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (label != null)
              TextButton(
                onPressed: () => widget.onGo(path!),
                child: Text('$label →'),
              ),
          ],
        ),
        Text(description),
        const SizedBox(height: 18),
        const Divider(),
      ],
    ),
  );
  Widget _art(String url, String fallback) {
    final asset = Image.asset(
      fallback,
      fit: BoxFit.cover,
      excludeFromSemantics: true,
    );
    final uri = endpointUri(c.settings.siteUrl).resolve(url);
    return url.isEmpty ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.userInfo.isNotEmpty
        ? asset
        : Image.network(
            '$uri',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => asset,
          );
  }

  Widget _stories(Map featured) {
    final art = SeasonalArt(RoomStyle(context).palette.season);
    final tile = InkWell(
      onTap: () => widget.onGo(articlePath(featured)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: _art(textOf(featured, 'cover_image'), art.article),
            ),
          ),
          const SizedBox(height: 10),
          Text(textOf(featured, 'category', tr('月读手记', 'Journal', '手記'))),
          Text(
            textOf(
              featured,
              'title',
              tr(
                '每一个故事，都值得被看见。',
                'Every story deserves a little light.',
                'すべての物語に光を。',
              ),
            ),
            style: const TextStyle(
              fontSize: 24,
              fontFamily: RoomStyle.serif,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(plainText(textOf(featured, 'excerpt'))),
          Text(userDisplayName(featured, prefix: 'author', fallback: '')),
        ],
      ),
    );
    final latest = _articles
        .where((a) => a['id'] != featured['id'])
        .take(4)
        .toList();
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('最近写下', 'Recent stories', '最近の記事')),
        if (latest.isEmpty)
          TextButton(
            onPressed: () => widget.onGo('/stage'),
            child: Text(tr('去主舞台发现更多故事', 'Discover more stories', 'もっと読む')),
          ),
        for (final (i, a) in latest.indexed)
          ListTile(
            leading: Text('0${i + 1}'),
            onTap: () => widget.onGo(articlePath(a)),
            title: Text(textOf(a, 'title')),
            subtitle: Text(userDisplayName(a, prefix: 'author', fallback: '')),
            trailing: const Icon(Icons.north_east),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (_, box) => box.maxWidth > 720
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 6, child: tile),
                const SizedBox(width: 40),
                Expanded(flex: 5, child: list),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [tile, const SizedBox(height: 20), list],
            ),
    );
  }

  Widget _places() {
    final art = SeasonalArt(RoomStyle(context).palette.season),
        pixel = mapOf(_data['pixel']);
    final places = [
      (
        '/gallery',
        tr('光影收藏', 'Collected light', '光のコレクション'),
        _art(textOf(mapOf(_data['gallery']), 'url'), art.gallery),
      ),
      (
        '/pixel',
        tr('像素里的宇宙', 'Little pixel worlds', 'ピクセルの宇宙'),
        pixel.isEmpty ? _art('', art.pixel) : HubPixelPreview(artwork: pixel),
      ),
      (
        '/wiki',
        tr('走进月读世界', 'The world of Tsukuyomi', '月読の世界へ'),
        _art('', 'assets/images/navigation/wiki-study.webp'),
      ),
      (
        '/game',
        tr('一起玩一会儿', 'A little time to play', '一緒に遊ぼう'),
        _art('', 'assets/images/navigation/kaguya-run.webp'),
      ),
    ];
    return LayoutBuilder(
      builder: (_, box) {
        final n = box.maxWidth > 900 ? 4 : 2;
        return Wrap(
          spacing: 12,
          runSpacing: 16,
          children: [
            for (final p in places)
              SizedBox(
                width: (box.maxWidth - 12 * (n - 1)) / n,
                child: InkWell(
                  onTap: () => widget.onGo(p.$1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: .92,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: p.$3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${p.$2} ↗',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

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
        title: Row(
          children: [
            Flexible(
              child: SiteText(
                '站内公告',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: RoomStyle(context).muted),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                announcementContent(_settings) ==
                        textOf(_settings, 'siteAnnouncement').trim()
                    ? noticeSummary(announcementContent(_settings))
                    : textOf(_settings, 'visitPopupTitle'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        minTileHeight: 52,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        enabled: _settings.isNotEmpty,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 20),
              child: SiteNotice(
                content: announcementContent(_settings),
                site: c.settings.siteUrl,
                onGo: widget.onGo,
              ),
            ),
          ),
        ],
      ),
    ),
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
}
