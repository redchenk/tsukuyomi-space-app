import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import '../settings/settings_dialog.dart';
import 'login_dialog.dart';
import 'site_message_anchor.dart';
import 'site_notification.dart';
import 'site_chrome.dart';
import 'site_share_actions.dart';
import 'site_widgets.dart';
import 'site_navigation.dart';
import '../../core/site_routes.dart';

class SitePage extends StatefulWidget {
  const SitePage({
    super.key,
    required this.controller,
    required this.path,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final VoidCallback? onTheme;
  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> with WidgetsBindingObserver {
  late final SiteRepository repo;
  late final SiteShareActions _shares;
  final _search = TextEditingController(), _composer = TextEditingController();
  final _scroll = ScrollController();
  final _messageAnchorKeys = <String, GlobalKey>{};
  String? _fragmentOverride;
  SiteMessageAnchor? _pendingAnchor;
  int _anchorRevision = 0;
  bool _anchorDataReady = false;
  Map<String, dynamic> _payload = {}, _extra = {};
  String _error = '',
      _notice = '',
      _scope = '',
      _category = '',
      _sort = 'featured',
      _tab = '会话';
  bool _loading = true, _working = false, _copying = false;
  bool _notificationBusy = false;
  int _page = 1, _request = 0, _writeRevision = 0;
  Timer? _debounce, _readingTimer;
  final _visibleReading = Stopwatch();
  String _readingToken = '';
  String _growthInviteSource = '';
  String _profileTab = '个人资料';
  final List<String> _diaryCursors = [''];
  final Set<String> _expandedReplies = {};
  bool _readingSent = false;
  RoomController get c => widget.controller;
  String get pagePath {
    final path = nativeSitePath(Uri.parse(widget.path)) ?? widget.path;
    return _fragmentOverride == null
        ? path
        : Uri.parse(path).replace(fragment: _fragmentOverride).toString();
  }

  String get route => Uri.parse(pagePath).path;
  bool get article =>
      nativeSitePath(Uri.parse(widget.path)) != null &&
      route.startsWith('/articles/');
  String get articleId =>
      Uri.parse(pagePath).pathSegments.elementAtOrNull(1) ?? '';
  bool get privatePage =>
      ['/growth', '/user', '/conversations', '/notifications'].contains(route);
  String get title => article ? '文章阅读' : siteDestinations[route] ?? '月读空间';
  String get draftKey => 'site-draft:${repo.scope}:$route';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repo = SiteRepository(
      api: c.site as SiteDataService,
      storage: c.storage,
      site: () => c.settings.siteUrl,
      accountId: () => c.account?.id,
    );
    _shares = SiteShareActions(
      repository: repo,
      canRecordGrowth: () => c.account != null && !c.sessionExpired,
    );
    _scope = repo.scope;
    _pendingAnchor = SiteMessageAnchor.parse(
      route,
      Uri.parse(pagePath).fragment,
    );
    _search.text = Uri.parse(pagePath).queryParameters['q'] ?? '';
    if (Uri.parse(pagePath).queryParameters['tab'] == 'diary') _tab = '日记';
    c.addListener(_accountChanged);
    _restoreDraft();
    _load();
  }

  @override
  void didUpdateWidget(covariant SitePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path == widget.path) return;
    final oldPath = nativeSitePath(Uri.parse(oldWidget.path)) ?? oldWidget.path;
    _fragmentOverride = null;
    final documentChanged =
        Uri.parse(oldPath).replace(fragment: '') !=
        Uri.parse(pagePath).replace(fragment: '');
    _queueAnchor(Uri.parse(pagePath).fragment, stopScrolling: false);
    if (documentChanged) {
      _request++;
      _writeRevision++;
      _working = false;
      _payload = {};
      _extra = {};
      _page = 1;
      _anchorDataReady = false;
      _expandedReplies.clear();
      _messageAnchorKeys.clear();
      _search.text = Uri.parse(pagePath).queryParameters['q'] ?? '';
      _tab = Uri.parse(pagePath).queryParameters['tab'] == 'diary'
          ? '日记'
          : '会话';
      _restoreDraft();
      _load();
    } else {
      _revealPendingAnchor();
    }
  }

  Future<void> _restoreDraft() async {
    final owner = repo.scope;
    final value = await c.storage.draft(draftKey);
    if (mounted && owner == repo.scope) _composer.text = value;
  }

  void _accountChanged() {
    if (!mounted) return;
    if (_scope != repo.scope) {
      _scope = repo.scope;
      _request++;
      _writeRevision++;
      _working = false;
      _payload = {};
      _extra = {};
      _notificationBusy = false;
      if (route == '/plaza') _page = 1;
      _cancelAnchor();
      _anchorDataReady = false;
      _messageAnchorKeys.clear();
      _expandedReplies.clear();
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _composer.clear();
      _restoreDraft();
      _load();
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _visibleReading.stop();
    if (state == AppLifecycleState.resumed &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      _load();
    }
  }

  @override
  void dispose() {
    _request++;
    _writeRevision++;
    _debounce?.cancel();
    _readingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_accountChanged);
    _search.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _go(String path) {
    try {
      final value = path.startsWith('#')
          ? Uri.parse(pagePath).replace(fragment: path.substring(1)).toString()
          : path;
      final target = resolveSiteTarget(c.settings.siteUrl, value).nativePath;
      if (target != null &&
          Uri.parse(target).replace(fragment: '') ==
              Uri.parse(pagePath).replace(fragment: '')) {
        setState(() => _queueAnchor(Uri.parse(target).fragment));
        _revealPendingAnchor();
        return;
      }
    } catch (_) {
      // Shared navigation handles unsupported or malformed URLs.
    }
    if (path == pagePath) return;
    navigateSite(context, c, path, replace: true);
  }

  void _cancelAnchor({bool stopScrolling = true}) {
    _anchorRevision++;
    _pendingAnchor = null;
    if (stopScrolling && _scroll.hasClients) _scroll.jumpTo(_scroll.offset);
  }

  void _queueAnchor(String fragment, {bool stopScrolling = true}) {
    _cancelAnchor(stopScrolling: stopScrolling);
    _fragmentOverride = fragment;
    _pendingAnchor = SiteMessageAnchor.parse(route, fragment);
    if (!stopScrolling) {
      final revision = _anchorRevision, owner = repo.scope;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            revision == _anchorRevision &&
            owner == repo.scope &&
            _scroll.hasClients) {
          _scroll.jumpTo(_scroll.offset);
        }
      });
    }
  }

  void _revealPendingAnchor() {
    final anchor = _pendingAnchor;
    if (anchor == null || !_anchorDataReady || !mounted) return;
    final rows = route == '/plaza'
        ? _plazaRows()
        : messageThreads(rowsOf(_extra['comments']));
    final location = findSiteMessageAnchor(rows, anchor.id);
    // Consume the request once, including missing/deleted targets. A later
    // rebuild or a manual page change must not pull the reader back.
    _pendingAnchor = null;
    if (location == null) return;
    setState(() {
      if (route == '/plaza') _page = location.page;
      if (location.reply) _expandedReplies.add(location.rootId);
    });
    final revision = _anchorRevision, owner = repo.scope, request = _request;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _anchorRevision ||
          owner != repo.scope ||
          request != _request ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final target = _messageAnchorKeys[anchor.id]?.currentContext;
      if (target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: .5,
          duration: article || MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
        ),
      );
    });
  }

  Future<void> _login() async {
    await showSiteLogin(context, c);
    if (mounted) await _load();
  }

  void _toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final ticket = ++_request;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (route == '/growth') {
        await _captureGrowthInvite();
        if (!mounted || ticket != _request) return;
      }
      if (!article &&
          !const {
            '/stage',
            '/plaza',
            '/growth',
            '/user',
            '/notifications',
            '/conversations',
          }.contains(route)) {
        throw const FormatException('此页面暂未提供原生版本');
      }
      String path;
      if (article) {
        path = '/api/articles/${Uri.encodeComponent(articleId)}';
      } else {
        path = switch (route) {
          '/plaza' => '/api/messages',
          '/growth' => '/api/growth/me',
          '/user' => '/api/user/profile',
          '/notifications' => _notificationPath(_page),
          '/conversations' =>
            _tab == '记忆'
                ? '/api/room/memory?view=manage&limit=30&offset=${(_page - 1) * 30}&q=${Uri.encodeQueryComponent(_search.text)}'
                : _tab == '日记'
                ? '/api/room/diary?cursor=${Uri.encodeQueryComponent(_diaryCursors.last)}'
                : '/api/room/chat?limit=100',
          _ =>
            '/api/articles?limit=6&page=$_page&sort=$_sort&category=${Uri.encodeQueryComponent(_category)}&q=${Uri.encodeQueryComponent(_search.text)}',
        };
      }
      if (_payload.isEmpty) {
        final saved = await repo.cached(path, private: privatePage);
        if (saved != null && mounted && ticket == _request) {
          setState(() {
            _payload = saved.payload;
            _notice = saved.notice;
          });
        }
      }
      final doc = await repo.read(path, private: privatePage);
      if (!mounted || ticket != _request) return;
      var payload = doc.payload;
      if (route == '/growth' && !doc.cached) {
        final claimed = await _claimGrowthInvite();
        if (!mounted || ticket != _request) return;
        if (claimed != null) payload = {...payload, 'data': claimed};
      }
      setState(() {
        _payload = payload;
        if (route == '/plaza') _anchorDataReady = true;
        if (route == '/notifications') {
          final page = mapOf(_payload['pagination'])['page'];
          if (page is num) _page = page.toInt().clamp(1, 0x7fffffff);
        }
        _notice = doc.notice;
        _loading = false;
      });
      if (route == '/notifications' && !doc.cached) {
        publishSiteUnread(
          context,
          notificationUnreadCount(
            _payload['unread'],
            _notificationItems(_payload),
          ),
        );
      }
      if (route == '/plaza') _revealPendingAnchor();
      if (article && !doc.cached) _beginReading(doc.payload);
      final extras = <String, String>{
        if ((article || route == '/plaza') && c.account != null)
          'likedMessages': '/api/messages/liked',
        if (article) 'comments': '/api/articles/$articleId/messages',
        if (article && c.account != null) ...{
          'bookmark': '/api/user/bookmarks/$articleId/status',
          'like': '/api/user/article-likes/$articleId/status',
        },
        if (route == '/plaza') ...{
          'stats': '/api/stats',
          'topics': '/api/messages/topics',
        },
        if (route == '/user') ...{
          'bookmarks': '/api/user/bookmarks',
          'articles': '/api/user/articles',
          'messages': '/api/messages/mine',
        },
        if (route == '/stage') 'categories': '/api/article-categories',
      };
      await Future.wait(
        extras.entries.map((entry) async {
          try {
            final data = await repo.read(
              entry.value,
              private: route == '/user',
            );
            if (mounted && ticket == _request) {
              setState(() {
                _extra[entry.key] = data.data;
                if (entry.key == 'comments') _anchorDataReady = true;
                if (data.notice.isNotEmpty) _notice = data.notice;
              });
              if (entry.key == 'comments') _revealPendingAnchor();
            }
          } catch (_) {
            if (mounted && ticket == _request) {
              setState(() => _notice = '部分内容暂未同步，请重试；本机内容已保留');
            }
          }
        }),
      );
    } catch (e) {
      if (mounted && ticket == _request) setState(() => _error = '$e');
    } finally {
      if (mounted && ticket == _request) setState(() => _loading = false);
    }
  }

  void _beginReading(Map<String, dynamic> payload) {
    _readingTimer?.cancel();
    _readingToken = textOf(mapOf(payload['reading']), 'token');
    if (_readingToken.isEmpty || _readingSent) return;
    _visibleReading
      ..reset()
      ..start();
    final scope = repo.scope;
    _readingTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || scope != repo.scope) {
        timer.cancel();
        return;
      }
      final active =
          ModalRoute.of(context)?.isCurrent == true &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (!active) {
        _visibleReading.stop();
        return;
      }
      _visibleReading.start();
      if (_visibleReading.elapsed.inSeconds < 13) return;
      timer.cancel();
      try {
        final result = await repo.api.request(
          c.settings.siteUrl,
          'POST',
          '/api/articles/$articleId/read',
          {'token': _readingToken},
        );
        if (mounted && repo.scope == scope) {
          _readingSent = true;
          final data = mapOf(result['data']);
          if (data['viewCount'] != null) {
            setState(
              () => (_payload['data'] as Map)['view_count'] = data['viewCount'],
            );
          }
        }
      } catch (_) {
        /* A manual refresh gets a fresh reading receipt. */
      }
    });
  }

  Future<Map<String, dynamic>?> _write(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (!mounted || _working) return null;
    if (c.account == null || c.sessionExpired) {
      await _login();
      return null;
    }
    final revision = ++_writeRevision, owner = repo.scope;
    setState(() => _working = true);
    try {
      final result = await repo.write(method, path, body);
      if (!mounted || revision != _writeRevision || owner != repo.scope) {
        return null;
      }
      return result;
    } catch (e) {
      if (mounted && revision == _writeRevision && owner == repo.scope) {
        _toast('$e');
      }
      return null;
    } finally {
      if (mounted && revision == _writeRevision && owner == repo.scope) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _submitPost({String? replyId, String? content}) async {
    final text = content ?? _composer.text.trim();
    if (text.isEmpty) return;
    final key = draftKey;
    final result = await _write(
      'POST',
      replyId == null ? '/api/messages' : '/api/messages/$replyId/reply',
      {
        'content': text,
        if (article && replyId == null) 'article_id': articleId,
      },
    );
    if (result == null || !mounted) return;
    if (replyId == null) {
      _composer.clear();
      await c.storage.saveDraft(key, '');
    }
    _toast(textOf(result, 'message', '已提交'));
    await _load();
  }

  Future<void> _editText({
    required String heading,
    required String initial,
    required String draftId,
    required Future<bool> Function(String) save,
    int maxLength = 4000,
  }) async {
    final owner = repo.scope;
    final key = 'editor:$owner:$draftId';
    final draft = await c.storage.draft(key);
    if (!mounted) return;
    final input = TextEditingController(
      text: draft.isNotEmpty ? draft : initial,
    );
    var working = false, failure = '';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(heading),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: input,
                    maxLines: 8,
                    minLines: 3,
                    maxLength: maxLength,
                    enabled: !working,
                    onChanged: (text) => c.storage.saveDraft(key, text),
                    decoration: InputDecoration(
                      hintText: siteTranslate(context, '写下你的内容…'),
                    ),
                  ),
                  if (failure.isNotEmpty)
                    Text(
                      failure,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(context),
              child: const SiteText('保留草稿并返回'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      if (input.text.trim().isEmpty) return;
                      change(() {
                        working = true;
                        failure = '';
                      });
                      try {
                        if (repo.scope != owner) {
                          throw const ApiFailure('账号已切换，草稿保留在原账号');
                        }
                        if (await save(input.text.trim())) {
                          await c.storage.saveDraft(key, '');
                          if (context.mounted) Navigator.pop(context);
                        } else {
                          failure = '提交未完成，内容已保留；检查网络或重新登录后重试';
                        }
                      } catch (e) {
                        failure = '$e';
                      }
                      if (context.mounted) change(() => working = false);
                    },
              child: Text(working ? '正在保存…' : '保存'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (mounted) await _load();
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const SiteText('确认操作'),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const SiteText('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const SiteText('确认'),
            ),
          ],
        ),
      ) ??
      false;
  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _page = 1;
      _load();
    });
  }

  Widget _heading(
    String heading,
    String subtitle, {
    String? kicker,
    Widget? action,
  }) => Padding(
    padding: EdgeInsets.symmetric(
      vertical: MediaQuery.sizeOf(context).width < 650 ? 8 : 18,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kicker != null)
          Text(
            kicker,
            style: TextStyle(
              letterSpacing: 3,
              fontSize: 11,
              color: RoomStyle(context).accent,
            ),
          ),
        if (kicker != null || MediaQuery.sizeOf(context).width >= 650)
          const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                heading,
                style: TextStyle(
                  fontSize: MediaQuery.sizeOf(context).width < 700 ? 28 : 38,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(color: RoomStyle(context).muted, height: 1.7),
        ),
      ],
    ),
  );
  Widget _searchBox(String hint) => SizedBox(
    width: 340,
    child: TextField(
      controller: _search,
      onChanged: _searchChanged,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(CupertinoIcons.search),
      ),
    ),
  );
  Widget _pill(String label, bool selected, VoidCallback tap) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => tap(),
      showCheckmark: false,
      selectedColor: RoomStyle(context).accent,
      labelStyle: TextStyle(
        fontSize: 12,
        color: selected ? Colors.white : RoomStyle(context).ink,
      ),
      shape: const StadiumBorder(side: BorderSide.none),
    ),
  );
  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.all(32),
    child: Center(child: Text(text)),
  );
  Widget _pager(int totalPages) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          onPressed:
              _page > 1 &&
                  !_loading &&
                  !(route == '/notifications' && _notificationBusy)
              ? () {
                  if (route == '/plaza') _cancelAnchor();
                  _page--;
                  if (route == '/plaza') {
                    setState(() {});
                  } else {
                    _load();
                  }
                }
              : null,
          child: const SiteText('上一页'),
        ),
        Text('第 $_page 页 / 共 $totalPages 页'),
        TextButton(
          onPressed:
              _page < totalPages &&
                  !_loading &&
                  !(route == '/notifications' && _notificationBusy)
              ? () {
                  if (route == '/plaza') _cancelAnchor();
                  _page++;
                  if (route == '/plaza') {
                    setState(() {});
                  } else {
                    _load();
                  }
                }
              : null,
          child: const SiteText('下一页'),
        ),
      ],
    ),
  );
  Widget _articleCard(Map a) => LayoutBuilder(
    builder: (context, box) {
      final desktop = box.maxWidth >= 650;
      final author = textOf(a, 'author_username').isNotEmpty
          ? textOf(a, 'author_username')
          : textOf(a, 'author', 'admin');
      final cover = textOf(a, 'cover_image');
      final metadata = Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (a['pinned_at'] != null)
            SiteText(
              '编辑推荐',
              style: TextStyle(
                color: RoomStyle(context).accent,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: RoomStyle(context).soft,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Text(
              textOf(a, 'category'),
              style: const TextStyle(fontSize: 11),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SiteAvatar(
                value: textOf(a, 'author_avatar'),
                name: author.toUpperCase(),
                site: c.settings.siteUrl,
                size: 22,
              ),
              const SizedBox(width: 6),
              Text(author, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ],
      );
      final body = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: desktop ? 30 : 20,
          vertical: desktop ? 24 : 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
          children: [
            metadata,
            const SizedBox(height: 12),
            Text(
              textOf(a, 'title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: desktop ? 23 : 21,
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              plainText(textOf(a, 'excerpt')),
              maxLines: desktop ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                height: 1.5,
                fontSize: 13,
                color: RoomStyle(context).muted,
              ),
            ),
            if (desktop) const Spacer() else const SizedBox(height: 20),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                Text(
                  '${a['view_count'] ?? 0} 阅读   ${a['like_count'] ?? 0} 点赞   ${a['bookmark_count'] ?? 0} 收藏',
                  style: const TextStyle(fontSize: 11),
                ),
                Text(
                  '约 ${textOf(a, 'read_time').replaceAll(RegExp(r'\s*min'), ' 分钟')}  ${dateText(a['published_at'] ?? a['created_at'])}',
                  style: TextStyle(
                    fontSize: 11,
                    color: RoomStyle(context).muted,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
      final image = cover.isEmpty
          ? null
          : Image.network(
              '${endpointUri(c.settings.siteUrl).resolve(cover)}',
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) =>
                  ColoredBox(color: RoomStyle(context).soft),
            );
      return InkWell(
        onTap: () => Navigator.pushNamed(context, '/articles/${a['id']}'),
        borderRadius: BorderRadius.circular(20),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: ColoredBox(
            color: RoomStyle(context).surface,
            child: desktop
                ? SizedBox(
                    height: 222,
                    child: Row(
                      children: [
                        Expanded(child: body),
                        if (image != null)
                          SizedBox(width: box.maxWidth * .45, child: image),
                      ],
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (image != null)
                        SizedBox(
                          height: (box.maxWidth * .52).clamp(172, 210),
                          child: image,
                        ),
                      body,
                    ],
                  ),
          ),
        ),
      );
    },
  );
  Widget _articles() {
    final rows = rowsOf(_payload['data']);
    final pages = (mapOf(_payload['pagination'])['totalPages'] as num? ?? 1)
        .toInt()
        .clamp(1, 99999);
    final categories = rowsOf(_extra['categories']);
    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final category in [
            '',
            ...categories.map((c) => textOf(c, 'name')),
          ])
            _pill(
              category.isEmpty ? '全部' : category,
              _category == category,
              () {
                _category = category;
                _page = 1;
                _load();
              },
            ),
        ],
      ),
    );
    final sorting = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: RoomStyle(context).soft,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in const {
            'featured': '精选优先',
            'daily': '每日推荐',
            'latest': '最新优先',
          }.entries)
            InkWell(
              onTap: () {
                _sort = item.key;
                _page = 1;
                _load();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: _sort == item.key
                      ? RoomStyle(context).surface
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Text(item.value, style: const TextStyle(fontSize: 11)),
              ),
            ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('主舞台', '博客文章'),
        ExpansionTile(
          minTileHeight: MediaQuery.sizeOf(context).width < 650 ? 32 : null,
          tilePadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          title: const SiteText('关于主舞台', style: TextStyle(fontSize: 12)),
          children: const [
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: SiteText('月读空间的文章与创作档案。浏览公告、传说、技术、二创和日常记录。'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: _searchChanged,
                decoration: InputDecoration(
                  hintText: siteTranslate(context, '搜索文章…'),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  prefixIcon: Icon(CupertinoIcons.search, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => openSiteLink(c.settings.siteUrl, '/editor'),
              icon: const Icon(CupertinoIcons.pencil, size: 16),
              label: const SiteText('新建投稿', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 850
              ? Row(
                  children: [
                    Expanded(child: filters),
                    const SizedBox(width: 16),
                    sorting,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [filters, sorting],
                ),
        ),
        const SizedBox(height: 12),
        Text(
          '${textOf(_payload, 'recommendationDate')} · 综合内容、有效阅读、点赞与收藏，每日轮换推荐，也让新作与较少曝光的创作被看见。',
          style: TextStyle(
            fontSize: 11,
            height: 1.7,
            color: RoomStyle(context).muted,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Text(
            '共 ${mapOf(_payload['pagination'])['total'] ?? rows.length} 篇  当前 ${(_page - 1) * 6 + (rows.isEmpty ? 0 : 1)}–${(_page - 1) * 6 + rows.length} 篇',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        for (final a in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: _articleCard(a),
          ),
        if (rows.isEmpty && !_loading) _empty('没有找到文章，试试其他关键词。'),
        _pager(pages),
      ],
    );
  }

  Widget _postComposer() => SiteCard(
    child: c.account == null
        ? Column(
            children: [
              const SiteText('登录后开放留言终端'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _login, child: const SiteText('去登录')),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _composer,
                maxLines: 4,
                maxLength: 4000,
                enabled: !_working,
                onChanged: (text) => c.storage.saveDraft(draftKey, text),
                decoration: InputDecoration(
                  hintText: article ? '写下你的评论…' : '问候、反馈和灵感都可以落在这里…',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _working ? null : _submitPost,
                  child: Text(_working ? '提交中…' : '发布'),
                ),
              ),
            ],
          ),
  );
  bool _messageLiked(Map m) =>
      m['viewer_liked'] == true ||
      (_extra['likedMessages'] is List &&
          (_extra['likedMessages'] as List).any((id) => '$id' == '${m['id']}'));

  Widget _message(Map m, {bool reply = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: SiteCard(
      key: ValueKey('site-message-${m['id']}'),
      padding: EdgeInsets.all(reply ? 14 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: _messageAnchorKeys.putIfAbsent('${m['id']}', GlobalKey.new),
            children: [
              SiteAvatar(
                value: textOf(m, 'avatar', textOf(m, 'author_avatar')),
                name: textOf(m, 'author', '访客'),
                site: c.settings.siteUrl,
                size: 32,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  textOf(m, 'author', '访客'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                dateText(m['created_at']),
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (reply && textOf(m, 'reply_to_author').isNotEmpty)
            Text(
              '回复 ${m['reply_to_author']}',
              style: TextStyle(fontSize: 12, color: RoomStyle(context).accent),
            ),
          SelectableText(
            textOf(m, 'content'),
            style: const TextStyle(height: 1.7),
          ),
          Wrap(
            children: [
              TextButton.icon(
                onPressed: _working || _messageLiked(m)
                    ? null
                    : () async {
                        if (await _write(
                              'POST',
                              '/api/messages/${m['id']}/like',
                            ) !=
                            null) {
                          await _load();
                        }
                      },
                icon: Icon(
                  _messageLiked(m)
                      ? CupertinoIcons.heart_fill
                      : CupertinoIcons.heart,
                  size: 16,
                ),
                label: Text('${m['like_count'] ?? 0}'),
              ),
              TextButton.icon(
                onPressed: () => _editText(
                  heading: '回复 ${textOf(m, 'author')}',
                  initial: '',
                  draftId: 'reply:${m['id']}',
                  save: (text) async =>
                      await _write('POST', '/api/messages/${m['id']}/reply', {
                        'content': text,
                      }) !=
                      null,
                ),
                icon: const Icon(CupertinoIcons.chat_bubble, size: 16),
                label: Text('回复 ${rowsOf(m['replies']).length}'),
              ),
              TextButton.icon(
                onPressed: _copying
                    ? null
                    : () => _copyLink(
                        '${m['article_id'] != null ? '/articles/${m['article_id']}' : '/plaza'}#${m['article_id'] != null ? 'comment' : 'msg'}-${m['id']}',
                        '链接已复制',
                        recordGrowth: false,
                      ),
                icon: const Icon(CupertinoIcons.link, size: 16),
                label: const SiteText('复制链接'),
              ),
            ],
          ),
          for (final child in rowsOf(m['replies']).take(
            _expandedReplies.contains('${m['id']}')
                ? rowsOf(m['replies']).length
                : 2,
          ))
            _message(child, reply: true),
          if (rowsOf(m['replies']).length > 2)
            TextButton(
              onPressed: () => setState(() {
                if (!_expandedReplies.add('${m['id']}')) {
                  _expandedReplies.remove('${m['id']}');
                }
              }),
              child: Text(
                _expandedReplies.contains('${m['id']}')
                    ? '收起回复'
                    : '查看全部 ${rowsOf(m['replies']).length} 条回复',
              ),
            ),
        ],
      ),
    ),
  );
  List<Map<String, dynamic>> _plazaRows() {
    var rows = messageThreads(rowsOf(_payload['data']));
    rows.sort(
      (a, b) => textOf(b, 'created_at').compareTo(textOf(a, 'created_at')),
    );
    final query = _search.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      rows = rows
          .where(
            (m) =>
                '${m['content']} ${m['author']}'.toLowerCase().contains(query),
          )
          .toList();
    }
    if (_sort == 'likes') {
      rows.sort(
        (a, b) => ((b['like_count'] as num?) ?? 0).compareTo(
          (a['like_count'] as num?) ?? 0,
        ),
      );
    }
    if (_sort == 'replies') {
      rows = rows.where((m) => rowsOf(m['replies']).isNotEmpty).toList();
    }
    if (_sort == 'mine') {
      rows = rows.where((m) => '${m['user_id']}' == c.account?.id).toList();
    }
    return rows;
  }

  Widget _plaza() {
    final rows = _plazaRows();
    final wall = SiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) => Column(
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: SiteText(
                        '01  留言墙',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (box.maxWidth > 650)
                      SizedBox(width: 300, child: _searchBox('搜索…')),
                    TextButton.icon(
                      onPressed: _loading ? null : _load,
                      icon: const Icon(CupertinoIcons.refresh, size: 16),
                      label: const SiteText('刷新'),
                    ),
                  ],
                ),
                if (box.maxWidth <= 650) ...[
                  const SizedBox(height: 14),
                  _searchBox('搜索…'),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            children: [
              for (final item in const {
                'latest': '最新',
                'likes': '高赞',
                'replies': '有回复',
                'mine': '我的',
              }.entries)
                _pill(
                  item.value,
                  _sort == item.key ||
                      (_sort == 'featured' && item.key == 'latest'),
                  () => setState(() {
                    _sort = item.key;
                    _page = 1;
                  }),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '${rows.length} 条匹配留言   第 $_page 页 / 共 ${(rows.length / 8).ceil().clamp(1, 99999)} 页 · 每页 8 条',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          _postComposer(),
          const SizedBox(height: 20),
          for (final row in rows.skip((_page - 1) * 8).take(8)) _message(row),
          _pager((rows.length / 8).ceil().clamp(1, 99999)),
          if (rows.isEmpty && !_loading) _empty('还没有匹配的留言。'),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final hero = ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: box.maxWidth >= 900 ? 270 : 0,
              ),
              child: SiteCard(
                padding: const EdgeInsets.all(30),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SiteText(
                      'TSUKUYOMI PLAZA',
                      style: TextStyle(
                        color: RoomStyle(context).accent,
                        fontSize: 11,
                        letterSpacing: 2,
                      ),
                    ),
                    SizedBox(height: box.maxWidth >= 900 ? 38 : 18),
                    SiteText(
                      '月读广场',
                      style: TextStyle(
                        fontSize: box.maxWidth < 650 ? 38 : 60,
                        fontWeight: FontWeight.w700,
                        color: RoomStyle(context).accent,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const SiteText(
                      '访客、创作者和路过的观测者在这里交换留言。问候、反馈和灵感都可以落在这里。',
                      style: TextStyle(height: 1.8),
                    ),
                  ],
                ),
              ),
            );
            final status = ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: box.maxWidth >= 900 ? 270 : 0,
              ),
              child: SiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SiteText(
                      '当前频道                 公共留言墙',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '广场状态                 ${_notice.isEmpty ? '在线' : '等待重连'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 22),
                    Text(
                      c.account == null ? '访客模式' : '欢迎，${c.account!.username}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      c.account == null
                          ? '当前可以浏览留言。登录后可发布、回复与点赞。'
                          : '在这里写下此刻的想法，与同行者相遇。',
                      style: const TextStyle(height: 1.7),
                    ),
                    const SizedBox(height: 18),
                    FilledButton(
                      onPressed: c.account == null
                          ? _login
                          : () => _go('/user'),
                      child: Text(c.account == null ? '去登录' : '个人中心'),
                    ),
                  ],
                ),
              ),
            );
            return box.maxWidth < 900
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [hero, const SizedBox(height: 16), status],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: hero),
                      const SizedBox(width: 20),
                      Expanded(flex: 3, child: status),
                    ],
                  );
          },
        ),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final item in {
                '站内文章': mapOf(_extra['stats'])['articles'],
                '注册访客': mapOf(_extra['stats'])['users'],
                '广场留言': mapOf(_extra['stats'])['messages'],
                '服务运行':
                    '${((mapOf(_extra['stats'])['uptime'] as num? ?? 0) / 86400).floor()}天${(((mapOf(_extra['stats'])['uptime'] as num? ?? 0) % 86400) / 3600).floor()}时',
              }.entries)
                SizedBox(
                  width:
                      (box.maxWidth - (box.maxWidth < 650 ? 12 : 36)) /
                      (box.maxWidth < 650 ? 2 : 4),
                  child: SiteCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.key),
                        const SizedBox(height: 10),
                        Text(
                          '${item.value ?? '—'}',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          const {
                            '站内文章': '主舞台内容池',
                            '注册访客': '已接入月读空间',
                            '广场留言': '仅统计公开主留言',
                            '服务运行': '后端在线时长',
                          }[item.key]!,
                          style: TextStyle(
                            fontSize: 11,
                            color: RoomStyle(context).muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth < 900
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [wall, const SizedBox(height: 20), _plazaSidebar()],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 7, child: wall),
                    const SizedBox(width: 24),
                    Expanded(flex: 3, child: _plazaSidebar()),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _plazaSidebar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SiteText(
              '热门话题',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 6,
              children: [
                for (final topic in rowsOf(_extra['topics']))
                  ActionChip(
                    label: Text('#${topic['topic'] ?? topic['name'] ?? ''}'),
                    onPressed: () {
                      _search.text =
                          '#${topic['topic'] ?? topic['name'] ?? ''}';
                      setState(() => _page = 1);
                    },
                  ),
              ],
            ),
            if (rowsOf(_extra['topics']).isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: SiteText(
                    '还没有话题，试试发布 #月读茶会#',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SiteText(
              '常驻访客',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            for (final item in const {
              '月读空间官方': 'https://github.com/redchenk/tsukuyomi-space',
              '辉夜姬博客': '/stage',
              '月光像素工坊': '/pixel/',
              '友链': '/friend-links',
              '友链申请': '/friend-links/apply',
            }.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(item.key, style: const TextStyle(fontSize: 14)),
                trailing: const Icon(CupertinoIcons.arrow_up_right, size: 14),
                onTap: () {
                  if (item.value == '/stage') {
                    _go('/stage');
                  } else {
                    openSiteLink(c.settings.siteUrl, item.value);
                  }
                },
              ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SiteText(
              '留言约定',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 14),
            SiteText(
              '保持友好，避免刷屏和敏感信息。\n\n友链申请请使用上方独立入口，审核状态可随时查看。\n\n反馈问题时尽量写清页面、操作和现象。',
              style: TextStyle(height: 1.7),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _article() {
    final a = mapOf(_payload['data']);
    final bookmarked = mapOf(_extra['bookmark'])['bookmarked'] == true;
    final liked = mapOf(_extra['like'])['liked'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(CupertinoIcons.back),
            label: const SiteText('返回主舞台'),
          ),
        ),
        SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                textOf(a, 'category'),
                style: TextStyle(color: RoomStyle(context).accent),
              ),
              _heading(
                textOf(a, 'title'),
                '${textOf(a, 'author_username', textOf(a, 'author'))} · ${dateText(a['created_at'])} · ${a['view_count'] ?? 0} 阅读',
              ),
              const Divider(height: 36),
              ArticleBody(
                content: textOf(a, 'content'),
                format: textOf(a, 'content_format', 'html'),
                site: c.settings.siteUrl,
                onNavigate: _go,
                initialAnchor: Uri.parse(widget.path).fragment,
                headers: {if (c.site.cookie != null) 'Cookie': c.site.cookie!},
              ),
              const SizedBox(height: 30),
              Wrap(
                spacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (await _write(
                            liked ? 'DELETE' : 'POST',
                            '/api/user/article-likes/$articleId',
                          ) !=
                          null) {
                        await _load();
                      }
                    },
                    icon: Icon(
                      liked ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                    ),
                    label: Text(liked ? '已点赞' : '点赞'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      if (await _write(
                            bookmarked ? 'DELETE' : 'POST',
                            '/api/user/bookmarks/$articleId',
                          ) !=
                          null) {
                        await _load();
                      }
                    },
                    icon: Icon(
                      bookmarked
                          ? CupertinoIcons.bookmark_fill
                          : CupertinoIcons.bookmark,
                    ),
                    label: Text(bookmarked ? '已收藏' : '收藏'),
                  ),
                  TextButton.icon(
                    onPressed: _copying
                        ? null
                        : () => _copyLink(
                            '/articles/${Uri.encodeComponent(articleId)}',
                            '文章链接已复制',
                          ),
                    icon: const Icon(CupertinoIcons.link),
                    label: const SiteText('复制链接'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _heading('评论', '写下阅读后的想法'),
        _postComposer(),
        const SizedBox(height: 18),
        for (final m in messageThreads(rowsOf(_extra['comments']))) _message(m),
      ],
    );
  }

  Future<void> _copyInvite() async {
    final invite = textOf(
      mapOf(mapOf(_payload['data'])['referral']),
      'inviteCode',
    );
    if (invite.isEmpty) return;
    await _copyLink(
      '/register?invite=${Uri.encodeQueryComponent(invite)}&redirect=%2Fgrowth',
      '邀请链接已复制',
      reloadGrowth: true,
    );
  }

  Future<void> _captureGrowthInvite() async {
    final origin = endpointUri(c.settings.siteUrl).origin;
    final code = (Uri.parse(pagePath).queryParameters['invite'] ?? '')
        .trim()
        .toUpperCase();
    if (!RegExp(r'^[A-F0-9]{10}$').hasMatch(code)) return;
    final source = '$origin:$code';
    if (_growthInviteSource == source) return;
    await c.storage.saveDraft('pending-referral:$origin', code);
    _growthInviteSource = source;
  }

  Future<Map<String, dynamic>?> _claimGrowthInvite() async {
    if (c.loading || c.account == null || c.sessionExpired) return null;
    final owner = repo.scope;
    final key = 'pending-referral:${endpointUri(c.settings.siteUrl).origin}';
    final code = await c.storage.draft(key);
    if (!mounted ||
        owner != repo.scope ||
        c.sessionExpired ||
        !RegExp(r'^[A-F0-9]{10}$').hasMatch(code)) {
      return null;
    }
    try {
      final result = await repo.write('POST', '/api/growth/referrals/claim', {
        'code': code,
      });
      if (!mounted || owner != repo.scope || c.sessionExpired) return null;
      if (await c.storage.draft(key) == code &&
          mounted &&
          owner == repo.scope) {
        await c.storage.saveDraft(key, '');
      }
      final state = mapOf(mapOf(result['data'])['state']);
      return state.isEmpty ? null : state;
    } on ApiFailure catch (e) {
      if (mounted &&
          owner == repo.scope &&
          e.status != null &&
          e.status! >= 400 &&
          e.status! < 500 &&
          await c.storage.draft(key) == code) {
        await c.storage.saveDraft(key, '');
      }
      rethrow;
    }
  }

  Future<void> _checkGrowthIn() async {
    if (_working || _loading) return;
    final result = await _write('POST', '/api/growth/check-in');
    if (result == null || !mounted) return;
    final award = mapOf(mapOf(result['data'])['award']);
    _toast(
      award['awarded'] == true
          ? '+${award['xp'] ?? 0} 经验${(award['bonusXp'] as num? ?? 0) > 0 ? '，连续七日 +${award['bonusXp']}' : ''}'
          : '签到成功',
    );
    await _load();
  }

  Future<void> _shareInvite() async {
    if (_copying || _working) return;
    final invite = textOf(
      mapOf(mapOf(_payload['data'])['referral']),
      'inviteCode',
    );
    if (invite.isEmpty) return;
    final url = endpointUri(c.settings.siteUrl)
        .resolve(
          '/register?invite=${Uri.encodeQueryComponent(invite)}&redirect=%2Fgrowth',
        )
        .toString();
    final owner = repo.scope;
    setState(() => _copying = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      ShareResultStatus status;
      try {
        status = (await SharePlus.instance.share(
          ShareParams(
            title: siteTranslate(context, '邀请同行者'),
            text:
                '${siteTranslate(context, '好友首次和八千代完成一轮聊天后，双方获得成长经验。')}\n$url',
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        )).status;
      } catch (_) {
        status = ShareResultStatus.unavailable;
      }
      if (!mounted ||
          owner != repo.scope ||
          status == ShareResultStatus.dismissed) {
        return;
      }
      var recorded = false;
      if (status == ShareResultStatus.unavailable) {
        final copied = await _shares.copyLink(
          url,
          onCopied: () => _toast('邀请链接已复制'),
        );
        recorded = copied.growthRecorded;
      } else if (c.account != null && !c.sessionExpired) {
        try {
          await repo.write('POST', '/api/growth/actions/share', {
            'platform': 'native',
          });
          recorded = true;
        } catch (_) {
          /* A share succeeds independently of the optional XP side effect. */
        }
      }
      if (mounted && owner == repo.scope && recorded) await _load();
    } catch (_) {
      if (mounted && owner == repo.scope) _toast('分享失败，请重试');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _copyLink(
    String path,
    String message, {
    bool reloadGrowth = false,
    bool recordGrowth = true,
  }) async {
    if (_copying) return;
    final owner = repo.scope;
    setState(() => _copying = true);
    try {
      final result = await _shares.copyLink(
        endpointUri(c.settings.siteUrl).resolve(path).toString(),
        recordGrowth: recordGrowth,
        onCopied: () {
          if (mounted && owner == repo.scope) _toast(message);
        },
      );
      if (!mounted || owner != repo.scope) return;
      if (reloadGrowth && result.growthRecorded) await _load();
    } catch (_) {
      if (mounted && owner == repo.scope) _toast('复制失败，请重试');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Widget _growth() {
    final state = mapOf(_payload['data']),
        level = mapOf(mapOf(_payload['data'])['level']);
    final streak = mapOf(state['streak']), today = mapOf(state['today']);
    final tasks = rowsOf(today['tasks']);
    final checked = tasks.any(
      (t) => t['key'] == 'checkin' && t['completed'] == true,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('月契成长', '每天一点自然互动，都会成为你与八千代的共同记录。', kicker: 'MOON BOND'),
        SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'LV.${level['level'] ?? 1}',
                style: TextStyle(
                  color: RoomStyle(context).accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                textOf(level, 'title', '初次连接'),
                style: const TextStyle(fontSize: 28),
              ),
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: ((level['progressPercent'] as num? ?? 0) / 100).clamp(
                  0,
                  1,
                ),
                minHeight: 6,
                borderRadius: BorderRadius.circular(5),
              ),
              const SizedBox(height: 12),
              Text(
                '${level['totalXp'] ?? 0} 经验 · 连续相伴 ${streak['current'] ?? 0} 天 · 最长 ${streak['longest'] ?? 0} 天',
              ),
              const SizedBox(height: 18),
              FilledButton(
                key: const Key('growth-check-in'),
                onPressed: checked || _working ? null : _checkGrowthIn,
                child: Text(checked ? '今日已领取' : '每日签到'),
              ),
            ],
          ),
        ),
        _heading(
          '今日约定',
          '${today['completed'] ?? 0} / ${today['total'] ?? tasks.length} 已完成',
        ),
        SiteCard(
          child: Column(
            children: [
              for (final task in tasks)
                ListTile(
                  leading: Icon(
                    task['completed'] == true
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                  ),
                  title: Text(textOf(task, 'label')),
                  subtitle: Text('+${task['xp'] ?? 0} 经验'),
                  trailing: task['completed'] == true
                      ? const SiteText('已完成')
                      : TextButton(
                          key: Key('growth-task-${task['key']}'),
                          onPressed: _working || _copying
                              ? null
                              : () {
                                  if (task['key'] == 'checkin') {
                                    _checkGrowthIn();
                                    return;
                                  }
                                  if (task['key'] == 'daily_share') {
                                    _shareInvite();
                                    return;
                                  }
                                  final path = textOf(task, 'path');
                                  if (siteDestinations.containsKey(path)) {
                                    _go(path);
                                  } else {
                                    openSiteLink(c.settings.siteUrl, path);
                                  }
                                },
                          child: const SiteText('去完成'),
                        ),
                ),
            ],
          ),
        ),
        _heading('邀请同行者', '好友首次和八千代完成一轮聊天后，双方获得成长经验。'),
        SiteCard(
          child: Wrap(
            spacing: 20,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '已完成 ${mapOf(state['referral'])['qualifiedCount'] ?? 0} · 待首次聊天 ${mapOf(state['referral'])['pendingCount'] ?? 0}',
              ),
              OutlinedButton(
                onPressed: _working || _copying ? null : _copyInvite,
                child: const SiteText('复制邀请链接'),
              ),
              OutlinedButton(
                key: const Key('growth-share-invite'),
                onPressed: _working || _copying ? null : _shareInvite,
                child: const SiteText('直接分享'),
              ),
            ],
          ),
        ),
        _heading('成长路径', '每一步相伴，都有记录。'),
        SiteCard(
          child: Wrap(
            spacing: 20,
            runSpacing: 20,
            children: [
              for (final item in rowsOf(state['levels']))
                SizedBox(
                  width: 150,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'LV.${item['level']}  ${item['title']}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: item['reached'] == true
                              ? RoomStyle(context).accent
                              : RoomStyle(context).muted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text('${item['minXp']} 经验'),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _heading('让创作持续获得回应', '有效阅读、首次点赞和首次收藏与网站使用相同的成长规则。'),
        SiteCard(
          child: Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              Text('有效阅读  +${mapOf(state['articles'])['viewXp'] ?? 0}'),
              Text('收到点赞  +${mapOf(state['articles'])['likeXp'] ?? 0}'),
              Text('收到收藏  +${mapOf(state['articles'])['bookmarkXp'] ?? 0}'),
            ],
          ),
        ),
        _heading('最近记录', ''),
        SiteCard(
          child: Column(
            children: [
              for (final event in rowsOf(state['recentEvents']))
                ListTile(
                  title: Text(textOf(event, 'label')),
                  subtitle: Text(
                    dateText(event['createdAt'] ?? event['created_at']),
                  ),
                  trailing: Text('+${event['xp']}'),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _memoryEditor([Map? memory]) async {
    var initial = '';
    if (memory != null) {
      try {
        final doc = await repo.read(
          '/api/room/memory/${memory['id']}',
          private: true,
        );
        initial = textOf(mapOf(doc.data), 'content');
      } catch (e) {
        _toast('$e');
        return;
      }
    }
    if (!mounted) return;
    await _editText(
      heading: memory == null ? '添加记忆' : '编辑记忆',
      initial: initial,
      draftId: 'memory:${memory?['id'] ?? 'new'}',
      save: (text) async =>
          await _write(
            memory == null ? 'POST' : 'PUT',
            '/api/room/memory${memory == null ? '' : '/${memory['id']}'}',
            {
              'content': text,
              'summary': text.substring(0, text.length.clamp(0, 120)),
              'type': memory?['type'] ?? 'fact',
              'captureChat': false,
            },
          ) !=
          null,
    );
  }

  Widget _conversations() {
    final data = _payload['data'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('会话与记忆', '与你在网站上的私人居所保持同步。'),
        Wrap(
          children: [
            for (final tab in ['会话', '记忆', '日记'])
              _pill(tab, _tab == tab, () {
                setState(() {
                  _tab = tab;
                  _diaryCursors
                    ..clear()
                    ..add('');
                  _page = 1;
                  _payload = {};
                });
                _load();
              }),
          ],
        ),
        if (_tab == '会话') ...[
          SiteCard(
            child: Row(
              children: [
                Expanded(
                  child: Text('${c.pendingCount} 轮等待同步 · ${c.syncStatus}'),
                ),
                TextButton(
                  onPressed: () async {
                    await c.sync();
                    await _load();
                  },
                  child: const SiteText('立即同步'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final m in rowsOf(data))
            SiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m['role'] == 'user' ? c.account?.username ?? '你' : '月见八千代',
                    style: TextStyle(color: RoomStyle(context).accent),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    textOf(m, 'content'),
                    style: const TextStyle(height: 1.7),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    dateText(m['createdAt']),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          if (rowsOf(data).isEmpty) _empty('还没有会话，去房间和八千代聊聊吧。'),
        ] else if (_tab == '记忆') ...[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _searchBox('检索记忆…'),
              FilledButton.icon(
                onPressed: _memoryEditor,
                icon: const Icon(CupertinoIcons.add),
                label: const SiteText('添加记忆'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          for (final m in rowsOf(mapOf(data)['items']))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      textOf(m, 'summary'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      textOf(m, 'content'),
                      style: const TextStyle(height: 1.7),
                    ),
                    Wrap(
                      children: [
                        TextButton(
                          onPressed: () => _memoryEditor(m),
                          child: const SiteText('编辑'),
                        ),
                        TextButton(
                          onPressed: () async {
                            if (await _confirm('删除这条记忆会同步到网站，无法撤销。')) {
                              if (await _write(
                                    'DELETE',
                                    '/api/room/memory/${m['id']}',
                                  ) !=
                                  null) {
                                await _load();
                              }
                            }
                          },
                          child: const SiteText('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          _pager(
            (((mapOf(data)['total'] as num? ?? 0) / 30).ceil()).clamp(1, 99999),
          ),
        ] else ...[
          for (final row in rowsOf(
            mapOf(data)['entries'],
          ).where((e) => e['deleted'] != true))
            SiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    textOf(mapOf(row['entry']), 'title', '八千代的日记'),
                    style: const TextStyle(fontSize: 22),
                  ),
                  const SizedBox(height: 14),
                  ArticleBody(
                    content: textOf(
                      mapOf(row['entry']),
                      'content',
                      textOf(mapOf(row['entry']), 'text'),
                    ),
                    format: 'markdown',
                    site: c.settings.siteUrl,
                    onNavigate: _go,
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 12,
            children: [
              if (_diaryCursors.length > 1)
                TextButton(
                  onPressed: () {
                    _diaryCursors.removeLast();
                    _load();
                  },
                  child: const SiteText('上一页'),
                ),
              if (mapOf(data)['nextCursor'] != null &&
                  '${mapOf(data)['nextCursor']}'.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _diaryCursors.add('${mapOf(data)['nextCursor']}');
                    _load();
                  },
                  child: const SiteText('下一页'),
                ),
            ],
          ),
          if (rowsOf(mapOf(data)['entries']).isEmpty) _empty('云端还没有日记。'),
        ],
      ],
    );
  }

  Widget _profile() {
    final profile = mapOf(_payload['data']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('个人中心', '你的资料、收藏与创作', kicker: 'USER CENTER'),
        SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SiteAvatar(
                value: textOf(profile, 'avatar'),
                name: textOf(profile, 'username'),
                site: c.settings.siteUrl,
                size: 88,
              ),
              const SizedBox(height: 18),
              Text(
                textOf(profile, 'username', c.account?.username ?? ''),
                style: const TextStyle(fontSize: 28),
              ),
              const SizedBox(height: 8),
              Text(textOf(profile, 'email')),
              const SizedBox(height: 16),
              Text(
                textOf(profile, 'bio', '写一句话介绍自己吧。'),
                style: const TextStyle(height: 1.7),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton(
                    onPressed: () => _editText(
                      heading: '编辑个人简介',
                      initial: textOf(profile, 'bio'),
                      draftId: 'profile-bio',
                      maxLength: 500,
                      save: (text) async =>
                          await _write('PUT', '/api/user/profile', {
                            'bio': text,
                          }) !=
                          null,
                    ),
                    child: const SiteText('编辑资料'),
                  ),
                  OutlinedButton(
                    onPressed: () => showRoomSettings(context, c),
                    child: const SiteText('模型与语音设置'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.pushNamed(context, '/notifications'),
                    child: const SiteText('通知'),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (await _confirm('退出当前账号？未同步内容仍保留在本机原账号下。')) {
                        await c.logout();
                        if (mounted) _go('/stage');
                      }
                    },
                    child: const SiteText('退出登录'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          children: [
            for (final tab in ['个人资料', '我的文章', '我的留言', '我的收藏'])
              _pill(
                tab,
                tab == _profileTab,
                () => setState(() => _profileTab = tab),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_profileTab == '个人资料')
          SiteCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SiteText(
                  '个人资料',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 20),
                Text('用户名  ${textOf(profile, 'username')}'),
                const SizedBox(height: 16),
                Text('邮箱  ${textOf(profile, 'email', '未绑定邮箱')}'),
                const SizedBox(height: 16),
                Text('加入时间  ${dateText(profile['created_at'])}'),
                const SizedBox(height: 16),
                Text(textOf(profile, 'bio', '写一句话介绍自己吧。')),
              ],
            ),
          ),
        if (_profileTab == '我的收藏') ...[
          for (final a in rowsOf(
            _extra['bookmarks'] is List
                ? _extra['bookmarks']
                : mapOf(_extra['bookmarks'])['items'],
          ))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _articleCard(a),
            ),
          if (rowsOf(_extra['bookmarks']).isEmpty) _empty('还没有收藏的文章。'),
        ],
        if (_profileTab == '我的文章') ...[
          for (final a in rowsOf(_extra['articles']))
            SiteCard(
              child: ListTile(
                title: Text(textOf(a, 'title')),
                subtitle: Text(textOf(a, 'status')),
                onTap: a['status'] == 'published'
                    ? () => Navigator.pushNamed(context, '/articles/${a['id']}')
                    : null,
              ),
            ),
          if (rowsOf(_extra['articles']).isEmpty) _empty('还没有发布文章。'),
        ],
        if (_profileTab == '我的留言') ...[
          for (final m in rowsOf(
            _extra['messages'] is List
                ? _extra['messages']
                : mapOf(_extra['messages'])['items'],
          ))
            _message(m),
          if (rowsOf(_extra['messages']).isEmpty) _empty('还没有留言。'),
        ],
      ],
    );
  }

  String _notificationPath(int page) =>
      '/api/user/notifications?limit=12&page=$page';

  List<SiteNotification> _notificationItems(Map<String, dynamic> payload) {
    final data = payload['data'];
    return rowsOf(data is List ? data : mapOf(data)['items'])
        .map((item) => SiteNotification(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<bool> _markNotificationRead(SiteNotification item) async {
    if (!item.unread) return true;
    if (_working || _notificationBusy || item.id.isEmpty) return false;
    final owner = repo.scope;
    setState(() => _notificationBusy = true);
    try {
      final result = await _write(
        'POST',
        '/api/user/notifications/${Uri.encodeComponent(item.id)}/read',
      );
      if (result == null || !mounted || owner != repo.scope) return false;
      await _applyNotificationRead(result, owner: owner, item: item);
      return mounted && owner == repo.scope;
    } finally {
      if (mounted && owner == repo.scope) {
        setState(() => _notificationBusy = false);
      }
    }
  }

  Future<void> _openNotification(SiteNotification item) async {
    final owner = repo.scope;
    if (await _markNotificationRead(item) &&
        mounted &&
        owner == repo.scope &&
        ModalRoute.of(context)?.isCurrent == true &&
        item.link.isNotEmpty) {
      _go(item.link);
    }
  }

  Future<void> _markAllNotificationsRead() async {
    if (_working || _notificationBusy) return;
    final owner = repo.scope;
    setState(() => _notificationBusy = true);
    try {
      final result = await _write('POST', '/api/user/notifications/read-all');
      if (result == null || !mounted || owner != repo.scope) return;
      await _applyNotificationRead(result, owner: owner);
    } finally {
      if (mounted && owner == repo.scope) {
        setState(() => _notificationBusy = false);
      }
    }
  }

  Future<void> _applyNotificationRead(
    Map<String, dynamic> result, {
    required String owner,
    SiteNotification? item,
  }) async {
    final items = _notificationItems(_payload);
    final all = item == null;
    final unread = all
        ? notificationUnreadCount(mapOf(result['data'])['count'] ?? 0, [])
        : notificationUnreadCount(
            result['unread'] ??
                (notificationUnreadCount(_payload['unread'], items) - 1),
            [],
          );
    publishSiteUnread(context, unread);
    Map<String, dynamic> update(Map<String, dynamic> payload) => {
      ...payload,
      'unread': unread,
      'data': [
        for (final row in _notificationItems(payload))
          if (all || row.id == item.id)
            row.read(response: all ? null : mapOf(result['data']))
          else
            row.data,
      ],
    };
    // Ignore a GET started before the mutation; it can contain the old state.
    _request++;
    setState(() {
      _payload = update(_payload);
      _loading = false;
    });
    final snapshot = Map<String, dynamic>.from(_payload), page = _page;
    final totalPages =
        (mapOf(snapshot['pagination'])['totalPages'] as num? ?? 1).toInt();
    try {
      await c.storage.saveDraft(
        'site-cache:$owner:${_notificationPath(page)}',
        jsonEncode(snapshot),
      );
      // Keep already visited pages consistent if a later refresh is offline.
      for (var otherPage = 1; otherPage <= totalPages; otherPage++) {
        if (owner != repo.scope) return;
        if (otherPage == page) continue;
        final path = _notificationPath(otherPage);
        final saved = await repo.cached(path, private: true);
        if (saved == null || owner != repo.scope) continue;
        await c.storage.saveDraft(
          'site-cache:$owner:$path',
          jsonEncode(update(saved.payload)),
        );
      }
    } catch (_) {
      if (mounted && owner == repo.scope) {
        setState(() => _notice = '已读状态已同步，本机缓存暂未保存');
      }
    }
  }

  Widget _notifications() {
    final rows = _notificationItems(_payload);
    final unread = notificationUnreadCount(_payload['unread'], rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('站内信', '这里会收纳你收到的回复、点赞和互动提醒。'),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('未读 $unread', key: const ValueKey('notification-count')),
            OutlinedButton(
              onPressed: unread > 0 && !_working && !_notificationBusy
                  ? _markAllNotificationsRead
                  : null,
              child: const SiteText('全部已读'),
            ),
            TextButton(
              onPressed: _loading || _working || _notificationBusy
                  ? null
                  : _load,
              child: const SiteText('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        for (final item in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SiteCard(
              child: InkWell(
                key: ValueKey('notification-${item.id}'),
                onTap: _working || _notificationBusy
                    ? null
                    : () => _openNotification(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (item.unread)
                          Semantics(
                            label: '未读',
                            child: Icon(
                              CupertinoIcons.circle_fill,
                              key: ValueKey('notification-unread-${item.id}'),
                              size: 8,
                              color: RoomStyle(context).accent,
                            ),
                          ),
                      ],
                    ),
                    if (item.data['created_at'] != null)
                      Text(
                        dateText(item.data['created_at']),
                        style: TextStyle(color: RoomStyle(context).muted),
                      ),
                    const SizedBox(height: 8),
                    Text(item.content),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (item.link.isNotEmpty)
                          TextButton(
                            onPressed: _working || _notificationBusy
                                ? null
                                : () => _openNotification(item),
                            child: const SiteText('查看'),
                          ),
                        if (item.unread)
                          TextButton(
                            key: ValueKey('notification-mark-${item.id}'),
                            onPressed: _working || _notificationBusy
                                ? null
                                : () => _markNotificationRead(item),
                            child: const SiteText('标为已读'),
                          )
                        else
                          const SiteText('已读'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        _pager(
          (mapOf(_payload['pagination'])['totalPages'] as num? ?? 1).toInt(),
        ),
        if (rows.isEmpty) _empty('暂时没有通知。'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/moonlit-lake.png',
              fit: BoxFit.cover,
            ),
          ),
          Positioned.fill(
            child: ColoredBox(color: p.background.withValues(alpha: .80)),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: MediaQuery.sizeOf(context).width < 650
                        ? 14
                        : 24,
                    vertical: MediaQuery.sizeOf(context).width < 650 ? 10 : 16,
                  ),
                  child: SiteHeader(
                    title: title,
                    username: c.account?.username,
                    role: c.sessionExpired ? null : c.account?.role,
                    onGo: _go,
                    onTheme: widget.onTheme,
                    onLogin: () {
                      if (c.account == null || c.sessionExpired) {
                        _login();
                      } else {
                        _go('/user');
                      }
                    },
                  ),
                ),
                if (c.sessionExpired)
                  MaterialBanner(
                    content: const SiteText('登录已过期，草稿和缓存仍在。重新登录后继续同步。'),
                    actions: [
                      TextButton(
                        onPressed: _login,
                        child: const SiteText('重新登录'),
                      ),
                    ],
                  ),
                if (_notice.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(_notice)),
                        TextButton(
                          onPressed: _loading ? null : _load,
                          child: const SiteText('重试'),
                        ),
                      ],
                    ),
                  ),
                if (_loading) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        MediaQuery.sizeOf(context).width < 650 ? 14 : 20,
                        10,
                        MediaQuery.sizeOf(context).width < 650 ? 14 : 20,
                        40,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: article
                                ? 940
                                : route == '/stage'
                                ? 1056
                                : 1216,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_error.isNotEmpty)
                                SiteCard(
                                  child: Column(
                                    children: [
                                      Text(_error),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 12,
                                        children: [
                                          FilledButton(
                                            onPressed: _load,
                                            child: const SiteText('重试'),
                                          ),
                                          if (privatePage || c.sessionExpired)
                                            OutlinedButton(
                                              onPressed: _login,
                                              child: const SiteText('登录'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              if (_payload.isNotEmpty)
                                article
                                    ? _article()
                                    : switch (route) {
                                        '/plaza' => _plaza(),
                                        '/growth' => _growth(),
                                        '/user' => _profile(),
                                        '/conversations' => _conversations(),
                                        '/notifications' => _notifications(),
                                        _ => _articles(),
                                      },
                              const SizedBox(height: 24),
                              SiteBeianFooter(path: widget.path),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
