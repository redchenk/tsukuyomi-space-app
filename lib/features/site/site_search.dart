import '../../core/site_localization.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/site_client.dart';
import '../../core/models.dart';
import '../room/room_controller.dart';
import 'site_widgets.dart';

class SiteControllerScope extends InheritedWidget {
  const SiteControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final RoomController controller;
  static RoomController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SiteControllerScope>()?.controller;
  @override
  bool updateShouldNotify(SiteControllerScope oldWidget) =>
      oldWidget.controller != controller;
}

const _aliases = {
  '/hub': '中枢 大厅 首页 home hub',
  '/room': '房间 私人居所 八千代 yachiyo chat room',
  '/stage': '文章 主舞台 创作 article stage',
  '/plaza': '广场 留言 评论 community plaza',
  '/wiki': '百科 角色 音乐 wiki',
  '/gallery': '图库 图片 插画 gallery',
  '/pixel': '像素 工坊 pixel arena',
  '/game': '游戏 辉夜快跑 game',
  '/friend-links': '友链 友情链接 friends',
  '/reality': '现实 关于 感谢 about',
  '/notifications': '通知 站内信 inbox notifications',
  '/user': '用户 个人中心 account profile',
  '/growth': '成长 月契 bond growth',
  '/attachments': '附件 上传 attachment',
};

List<MapEntry<String, String>> searchSitePages(
  String query, {
  required bool authenticated,
}) {
  final terms = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((v) => v.isNotEmpty);
  return siteDestinations.entries.where((item) {
    if (!authenticated &&
        {
          '/user',
          '/growth',
          '/notifications',
          '/attachments',
          '/conversations',
        }.contains(item.key)) {
      return false;
    }
    final text = '${item.key} ${item.value} ${_aliases[item.key] ?? ''}'
        .toLowerCase();
    return terms.every(text.contains);
  }).toList();
}

final _searchDialogs = Expando<Future<void>>('site-search');
Future<void> showSiteSearch(
  BuildContext context,
  RoomController controller,
  ValueChanged<String> onGo,
) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final previous = _searchDialogs[navigator];
  if (previous != null) return previous;
  final next = showDialog<void>(
    context: context,
    builder: (_) => _SiteSearch(controller: controller, onGo: onGo),
  );
  _searchDialogs[navigator] = next;
  return next.whenComplete(() => _searchDialogs[navigator] = null);
}

class _SiteSearch extends StatefulWidget {
  const _SiteSearch({required this.controller, required this.onGo});
  final RoomController controller;
  final ValueChanged<String> onGo;
  @override
  State<_SiteSearch> createState() => _SiteSearchState();
}

class _SiteSearchState extends State<_SiteSearch> {
  final _input = TextEditingController();
  Timer? _debounce;
  int _run = 0;
  bool _loading = false;
  String _error = '';
  List<Map<String, dynamic>> _articles = [];
  String get query => _input.text.trim();
  RoomController get c => widget.controller;
  List<MapEntry<String, String>> get pages => searchSitePages(
    query,
    authenticated: c.account != null && !c.sessionExpired,
  );
  @override
  void initState() {
    super.initState();
    c.addListener(_changedAccount);
  }

  void _changedAccount() {
    if (mounted) setState(() {});
  }

  void _changed(String _) {
    _run++;
    _debounce?.cancel();
    setState(() {
      _articles = [];
      _error = '';
      _loading = query.isNotEmpty;
    });
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final run = ++_run, site = c.settings.siteUrl;
    if (query.isEmpty) return;
    try {
      if (c.site is! SiteDataService) throw const ApiFailure('站点连接不可用');
      final path = Uri(
        path: '/api/live/${DateTime.now().microsecondsSinceEpoch}/articles',
        queryParameters: {'search': query, 'limit': '4'},
      );
      final result = await (c.site as SiteDataService).request(
        site,
        'GET',
        '$path',
      );
      if (!mounted || run != _run || site != c.settings.siteUrl) return;
      final data = result['data'];
      setState(
        () => _articles = rowsOf(
          data is List ? data : mapOf(data)['articles'] ?? mapOf(data)['items'],
        ),
      );
    } catch (_) {
      if (mounted && run == _run) setState(() => _error = '文章暂时加载失败，页面入口仍可使用。');
    } finally {
      if (mounted && run == _run) setState(() => _loading = false);
    }
  }

  void _go(String path) {
    Navigator.pop(context);
    widget.onGo(path);
  }

  void _submit() {
    if (pages.isNotEmpty) {
      _go(pages.first.key);
    } else if (query.isNotEmpty) {
      _go('/stage?q=${Uri.encodeQueryComponent(query)}');
    }
  }

  @override
  void dispose() {
    _run++;
    _debounce?.cancel();
    c.removeListener(_changedAccount);
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 650, maxHeight: 700),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: SiteText('想找些什么？', style: TextStyle(fontSize: 22)),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: siteTranslate(context, '关闭搜索'),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              autofocus: true,
              maxLength: 120,
              onChanged: _changed,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: siteTranslate(context, '搜索页面和公开文章'),
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  onPressed: _submit,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (pages.isNotEmpty)
                    const SiteText(
                      '页面入口',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  for (final item in pages)
                    ListTile(
                      title: Text(siteDestinationLabel(context, item.key)),
                      subtitle: Text(item.key),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _go(item.key),
                    ),
                  if (query.isNotEmpty) ...[
                    const Divider(),
                    const SiteText(
                      '公开文章',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      )
                    else if (_error.isNotEmpty)
                      ListTile(
                        title: Text(_error),
                        trailing: TextButton(
                          onPressed: _search,
                          child: const SiteText('重试'),
                        ),
                      )
                    else ...[
                      for (final article in _articles)
                        ListTile(
                          title: Text(textOf(article, 'title')),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _go(
                            '/articles/${Uri.encodeComponent(textOf(article, 'id'))}',
                          ),
                        ),
                      if (_articles.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: SiteText('没有找到匹配内容，换个关键词试试。'),
                        ),
                      if (_articles.isNotEmpty)
                        TextButton(
                          onPressed: () => _go(
                            '/stage?q=${Uri.encodeQueryComponent(query)}',
                          ),
                          child: const SiteText('查看全部文章结果'),
                        ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
