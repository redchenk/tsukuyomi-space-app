import '../../core/site_localization.dart';

import 'package:flutter/material.dart';

import '../../core/site_client.dart';
import '../../core/models.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'login_dialog.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class UserProfilePage extends StatefulWidget {
  const UserProfilePage({
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
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late final SiteRepository _repo;
  Map<String, dynamic> _profile = {}, _level = {};
  String _scope = '', _error = '', _notice = '', _category = '';
  bool _loading = true, _following = false;
  int _generation = 0;
  RoomController get c => widget.controller;
  String get username =>
      Uri.parse(widget.path).pathSegments.elementAtOrNull(1)?.trim() ?? '';
  Map<String, dynamic> get user => mapOf(_profile['user']);
  Map<String, dynamic> get stats => mapOf(_profile['stats']);
  Map<String, dynamic> get viewer => mapOf(_profile['viewer']);
  List<Map<String, dynamic>> get articles => rowsOf(_profile['articles']);
  bool get isSelf =>
      !c.sessionExpired &&
      (viewer['isSelf'] == true || c.account?.id == user['id']?.toString());
  @override
  void initState() {
    super.initState();
    _repo = SiteRepository(
      api: c.site as SiteDataService,
      storage: c.storage,
      site: () => c.settings.siteUrl,
      accountId: () => c.sessionExpired ? null : c.account?.id,
    );
    _scope = _repo.scope;
    c.addListener(_accountChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant UserProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _generation++;
      _profile = {};
      _level = {};
      _category = '';
      _following = false;
      _load();
    }
  }

  void _accountChanged() {
    if (_scope != _repo.scope) {
      _scope = _repo.scope;
      _generation++;
      _profile = {};
      _level = {};
      _following = false;
      _load();
    }
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final ticket = ++_generation, name = username;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (name.isEmpty) throw StateError('用户不存在');
      final result = await _repo.read(
        '/api/user/public/${Uri.encodeComponent(name)}',
      );
      if (!mounted || ticket != _generation) return;
      setState(() {
        _profile = mapOf(result.data);
        _notice = result.notice;
        _loading = false;
      });
      final id = textOf(user, 'id');
      if (RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
        try {
          final levels = await _repo.read(
            '/api/growth/public?ids=${Uri.encodeQueryComponent(id)}',
          );
          if (mounted && ticket == _generation) {
            setState(
              () => _level =
                  rowsOf(levels.data)
                      .where((item) => item['userId'] == id)
                      .firstOrNull ??
                  {},
            );
          }
        } catch (_) {
          /* Public profile remains usable if the level service fails. */
        }
      }
    } catch (e) {
      if (mounted && ticket == _generation) {
        setState(() {
          _error = '$e';
          _profile = {};
        });
      }
    } finally {
      if (mounted && ticket == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFollow() async {
    if (_following || isSelf || user['id'] == null) return;
    if (c.account == null || c.sessionExpired) {
      await showSiteLogin(context, c);
      return;
    }
    final owner = _repo.scope, target = textOf(user, 'id'), name = username;
    setState(() {
      _following = true;
      _error = '';
    });
    try {
      final result = await _repo.write(
        viewer['isFollowing'] == true ? 'DELETE' : 'POST',
        '/api/user/follow/${Uri.encodeComponent(target)}',
      );
      if (!mounted ||
          owner != _repo.scope ||
          username != name ||
          textOf(user, 'id') != target) {
        return;
      }
      final response = mapOf(result['data']);
      setState(() {
        _profile['viewer'] = {
          ...viewer,
          'isFollowing': response['isFollowing'] == true,
        };
        _profile['stats'] = {
          ...stats,
          if (response['followers'] != null) 'followers': response['followers'],
          if (response['following'] != null) 'following': response['following'],
        };
      });
    } catch (e) {
      if (mounted && owner == _repo.scope && username == name) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && owner == _repo.scope && username == name) {
        setState(() => _following = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    c.removeListener(_accountChanged);
    super.dispose();
  }

  String _articlePath(Map item) =>
      '/articles/${Uri.encodeComponent(textOf(item, 'id'))}${textOf(item, 'slug').isEmpty ? '' : '/${Uri.encodeComponent(textOf(item, 'slug'))}'}';
  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '${userDisplayName(user, fallback: username)} 的公开主页',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_notice.isNotEmpty)
          nativeSiteFeedback(context, _notice, retry: _load),
        if (_error.isNotEmpty)
          nativeSiteFeedback(context, _error, error: true, retry: _load),
        if (_loading && _profile.isEmpty)
          const Center(child: CircularProgressIndicator()),
        if (_profile.isNotEmpty) ...[
          NativeSiteSection(
            translate: false,
            title: userDisplayName(user, fallback: username),
            subtitle: textOf(user, 'bio', '这位创作者还没有写下个人简介。'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SiteAvatar(
                  value: textOf(user, 'avatar'),
                  name: userDisplayName(user, fallback: username),
                  site: c.settings.siteUrl,
                  size: 90,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Chip(
                      label: SiteText(
                        ['admin', 'super_admin'].contains(user['role'])
                            ? '管理员'
                            : '创作者',
                      ),
                    ),
                    if (_level.isNotEmpty)
                      Chip(
                        label: Text('Lv.${_level['level']} ${_level['title']}'),
                      ),
                    Chip(
                      label: Text(
                        siteTr(
                          context,
                          'nativeProfileJoinedAt',
                          fallback: '加入于 {date}',
                          params: {'date': dateText(user['created_at'])},
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (isSelf)
                      FilledButton.icon(
                        onPressed: () => widget.onGo('/user-center'),
                        icon: const Icon(Icons.edit_outlined),
                        label: const SiteText('编辑个人资料'),
                      )
                    else
                      FilledButton.icon(
                        key: const Key('profile-follow'),
                        onPressed: _following ? null : _toggleFollow,
                        icon: Icon(
                          viewer['isFollowing'] == true
                              ? Icons.person_remove_outlined
                              : Icons.person_add_outlined,
                        ),
                        label: SiteText(
                          _following
                              ? '正在更新关注状态'
                              : viewer['isFollowing'] == true
                              ? '取消关注'
                              : '关注作者',
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => widget.onGo('/stage'),
                      icon: const Icon(Icons.book_outlined),
                      label: const SiteText('回到主舞台'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          NativeSiteSection(
            title: '创作档案',
            child: LayoutBuilder(
              builder: (context, box) {
                final columns = box.maxWidth >= 700 ? 4 : 2;
                return Wrap(
                  runSpacing: 20,
                  children: [
                    for (final entry in const {
                      'articles': '公开文章',
                      'totalViews': '累计阅读',
                      'followers': '关注者',
                      'following': '正在关注',
                    }.entries)
                      SizedBox(
                        width: box.maxWidth / columns,
                        child: Column(
                          children: [
                            Text(
                              '${stats[entry.key] ?? 0}',
                              style: const TextStyle(fontSize: 30),
                            ),
                            Text(
                              entry.value,
                              style: TextStyle(color: RoomStyle(context).muted),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          NativeSiteSection(
            title: '公开文章',
            subtitle: '${articles.length} 篇公开创作',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (articles.isEmpty)
                  const SiteText('暂无公开文章。当这位用户发布文章后，会在这里形成公开创作列表。'),
                if (articles.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: const SiteText('全部'),
                        selected: _category.isEmpty,
                        onSelected: (_) => setState(() => _category = ''),
                      ),
                      for (final category
                          in articles
                              .map((item) => textOf(item, 'category'))
                              .where((value) => value.isNotEmpty)
                              .toSet())
                        ChoiceChip(
                          label: Text(category),
                          selected: _category == category,
                          onSelected: (_) =>
                              setState(() => _category = category),
                        ),
                    ],
                  ),
                const SizedBox(height: 18),
                for (final article in articles.where(
                  (item) => _category.isEmpty || item['category'] == _category,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: SiteCard(
                      child: InkWell(
                        onTap: () => widget.onGo(_articlePath(article)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (textOf(article, 'cover_image').isNotEmpty)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: nativeSiteImage(
                                  c.settings.siteUrl,
                                  textOf(article, 'cover_image'),
                                  height: 160,
                                  width: double.infinity,
                                  label: textOf(article, 'title'),
                                ),
                              ),
                            const SizedBox(height: 12),
                            Text(
                              '${article['category'] ?? '未分类'} · ${dateText(article['publish_date'] ?? article['created_at'])} · ${article['view_count'] ?? 0} 次阅读',
                              style: TextStyle(
                                fontSize: 12,
                                color: RoomStyle(context).muted,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              textOf(article, 'title'),
                              style: const TextStyle(fontSize: 23),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              textOf(article, 'excerpt', '这篇文章还没有摘要。'),
                              style: const TextStyle(height: 1.8),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () =>
                                    widget.onGo(_articlePath(article)),
                                icon: const Icon(Icons.arrow_forward, size: 16),
                                label: const SiteText('阅读'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (articles.isNotEmpty)
            NativeSiteSection(
              title: '最新文章',
              subtitle: textOf(articles.first, 'title'),
              child: OutlinedButton(
                onPressed: () => widget.onGo(_articlePath(articles.first)),
                child: const SiteText('查看最新文章'),
              ),
            ),
        ],
      ],
    ),
  );
}
