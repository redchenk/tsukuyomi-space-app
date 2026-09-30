import '../../core/site_localization.dart';

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'hub_pixel_preview.dart';
import 'login_dialog.dart';
import 'native_auth_page.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class UserCenterPage extends StatefulWidget {
  const UserCenterPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<UserCenterPage> createState() => _UserCenterPageState();
}

class _UserCenterPageState extends State<UserCenterPage> {
  RoomController get c => widget.controller;
  String get _accountScope =>
      '${endpointUri(c.settings.siteUrl).origin}:${c.account?.id ?? 'guest'}';
  String _scope = '', _tab = 'profile', _error = '', _notice = '';
  int _epoch = 0, _page = 1;
  bool _loading = true, _saving = false;
  Map<String, dynamic> _profile = {}, _growth = {};
  final Map<String, List<Map<String, dynamic>>> _content = {};
  final _nickname = TextEditingController(),
      _bio = TextEditingController(),
      _search = TextEditingController(),
      _currentPassword = TextEditingController(),
      _newPassword = TextEditingController(),
      _confirmPassword = TextEditingController();
  bool get loggedIn => !c.loading && c.account != null && !c.sessionExpired;
  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (!loggedIn) throw const ApiFailure('请先登录');
    final scope = _accountScope;
    final result = await (c.site as SiteDataService).request(
      c.settings.siteUrl,
      method,
      path,
      body,
    );
    if (!mounted || scope != _accountScope || !loggedIn) {
      throw const ApiFailure('账号已切换，请重试');
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _scope = '$_accountScope:${c.sessionExpired}:${c.loading}';
    c.addListener(_accountChanged);
    _load();
  }

  void _accountChanged() {
    final identity = '$_accountScope:${c.sessionExpired}:${c.loading}';
    if (_scope != identity) {
      _scope = identity;
      _epoch++;
      _profile = {};
      _growth = {};
      _content.clear();
      for (final field in [
        _nickname,
        _bio,
        _search,
        _currentPassword,
        _newPassword,
        _confirmPassword,
      ]) {
        field.clear();
      }
      _saving = false;
      _error = '';
      _notice = '';
      _page = 1;
      _load();
    }
  }

  @override
  void dispose() {
    _epoch++;
    c.removeListener(_accountChanged);
    for (final field in [
      _nickname,
      _bio,
      _search,
      _currentPassword,
      _newPassword,
      _confirmPassword,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch, scope = _accountScope;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      if (!loggedIn) return;
      if (c.site is! SiteDataService) throw const ApiFailure('站点连接不可用');
      final profile = mapOf(
        (await _request('GET', '/api/user/profile'))['data'],
      );
      if (!mounted || epoch != _epoch || scope != _accountScope) return;
      await c.updateAccountProfile(profile);
      if (!mounted || epoch != _epoch || scope != _accountScope) return;
      setState(() {
        _profile = profile;
        _nickname.text = userDisplayName(
          profile,
          fallback: c.account!.displayName,
        );
        _bio.text = textOf(profile, 'bio');
      });
      // Each panel reports its own failure; an optional endpoint cannot hide a
      // successfully loaded profile or erase another panel's existing results.
      final tab = _tab;
      if (tab == 'profile') {
        final growth = mapOf((await _request('GET', '/api/growth/me'))['data']);
        if (mounted && epoch == _epoch && scope == _accountScope) {
          setState(() => _growth = growth);
        }
      } else if (tab != 'security') {
        final path = switch (tab) {
          'articles' =>
            '/api/user/articles/live/${DateTime.now().millisecondsSinceEpoch}',
          'messages' => '/api/messages/mine?limit=100',
          'bookmarks' => '/api/user/bookmarks?limit=80',
          'pixel' => '/api/pixel-art/manage?limit=100',
          _ => '/api/user/articles',
        };
        final data = (await _request('GET', path))['data'];
        final rows = rowsOf(data is List ? data : mapOf(data)['items']);
        if (mounted && epoch == _epoch && scope == _accountScope) {
          setState(() => _content[tab] = rows);
        }
      }
    } catch (e) {
      if (mounted && epoch == _epoch && scope == _accountScope) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && epoch == _epoch && scope == _accountScope) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _write(
    String method,
    String path,
    Map<String, dynamic>? body,
    String notice, {
    bool reload = true,
  }) async {
    if (_saving || _loading) return;
    final scope = _accountScope, epoch = _epoch;
    setState(() {
      _saving = true;
      _error = '';
      _notice = '';
    });
    try {
      await _request(method, path, body);
      if (!mounted || scope != _accountScope || epoch != _epoch) return;
      setState(() => _notice = notice);
      if (reload) await _load();
    } catch (e) {
      if (mounted && scope == _accountScope && epoch == _epoch) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && scope == _accountScope) setState(() => _saving = false);
    }
  }

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const SiteText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const SiteText('确认'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _avatar() async {
    if (_saving || _loading) return;
    final scope = _accountScope;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '头像图片',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
            mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
          ),
        ],
      );
      if (file == null || !mounted || scope != _accountScope) return;
      if (await file.length() > 20 * 1024 * 1024) {
        throw const ApiFailure('请选择小于 20 MB 的图片');
      }
      final bytes = await file.readAsBytes();
      final original = await ui.instantiateImageCodec(bytes);
      final frame = await original.getNextFrame();
      final scale = math.min(
        1.0,
        420 / math.max(frame.image.width, frame.image.height),
      );
      var width = (frame.image.width * scale).round().clamp(1, 420),
          height = (frame.image.height * scale).round().clamp(1, 420);
      frame.image.dispose();
      original.dispose();
      List<int>? encoded;
      do {
        final codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: width,
          targetHeight: height,
        );
        final resized = await codec.getNextFrame();
        final data = await resized.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        resized.image.dispose();
        codec.dispose();
        if (data == null) throw const ApiFailure('图片无法解码');
        encoded = data.buffer.asUint8List();
        width = (width * .8).round().clamp(1, 420);
        height = (height * .8).round().clamp(1, 420);
      } while (encoded.length > 256 * 1024);
      if (!mounted || scope != _accountScope) return;
      await _write('POST', '/api/user/avatar', {
        'avatar': 'data:image/png;base64,${base64Encode(encoded)}',
      }, '头像已更新');
    } catch (e) {
      if (mounted && scope == _accountScope) setState(() => _error = '$e');
    }
  }

  Future<void> _password() async {
    final password = _newPassword.text;
    if (password.length < 8 ||
        password != _confirmPassword.text ||
        _currentPassword.text.isEmpty) {
      setState(
        () => _error = password.length < 8
            ? '新密码至少 8 位'
            : password != _confirmPassword.text
            ? '两次新密码不一致'
            : '请输入当前密码',
      );
      return;
    }
    await _write(
      'PUT',
      '/api/user/password',
      {'currentPassword': _currentPassword.text, 'newPassword': password},
      '密码已更新',
      reload: false,
    );
    if (mounted && _error.isEmpty) {
      _currentPassword.clear();
      _newPassword.clear();
      _confirmPassword.clear();
    }
  }

  Future<void> _editMessage(Map<String, dynamic> row) async {
    final scope = _accountScope,
        draftKey = '$_accountScope.message-edit.${row['id']}';
    final saved = await c.storage.draft(draftKey);
    if (!mounted || scope != _accountScope) return;
    final field = TextEditingController(
      text: saved.isEmpty ? textOf(row, 'content') : saved,
    );
    final content = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const SiteText('编辑留言'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: field,
            maxLines: 8,
            maxLength: 2000,
            onChanged: (value) => c.storage.saveDraft(draftKey, value),
            decoration: InputDecoration(
              labelText: siteTranslate(context, '留言内容'),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const SiteText('保存'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 350), field.dispose);
    if (content == null || !mounted || scope != _accountScope) return;
    await _write(
      'PATCH',
      '/api/messages/${Uri.encodeComponent('${row['id']}')}',
      {'content': content},
      '留言已保存；修改后将重新审核',
    );
    if (_error.isEmpty && scope == _accountScope) {
      await c.storage.saveDraft(draftKey, '');
    }
  }

  Widget _profileView() => NativeSiteSection(
    title: '个人资料',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('用户名：${textOf(_profile, 'username')}'),
        Text('ID：${textOf(_profile, 'id')}'),
        const SiteText('登录用户名与用户 ID 不可修改'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('account-nickname'),
          controller: _nickname,
          enabled: !_saving && !_loading,
          decoration: InputDecoration(labelText: siteTranslate(context, '昵称')),
        ),
        const SizedBox(height: 8),
        Text('邮箱：${textOf(_profile, 'email', '未绑定邮箱')}'),
        const SizedBox(height: 8),
        Text('加入时间：${dateText(_profile['created_at'])}'),
        const SizedBox(height: 20),
        TextField(
          controller: _bio,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(
            labelText: siteTranslate(context, '个人简介'),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: _saving || _loading
              ? null
              : () {
                  final invalid = nicknameError(_nickname.text);
                  if (invalid != null) {
                    setState(() => _error = invalid);
                    return;
                  }
                  _write('PUT', '/api/user/profile', {
                    'bio': _bio.text,
                    'nickname': _nickname.text.trim(),
                  }, '个人资料已保存');
                },
          child: const SiteText('保存资料'),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => widget.onGo(
                '/users/${Uri.encodeComponent(textOf(_profile, 'username'))}',
              ),
              child: const SiteText('查看公开主页'),
            ),
            OutlinedButton(
              onPressed: () => widget.onGo('/growth'),
              child: Text(
                '月契成长 · ${mapOf(_growth['summary'])['level'] ?? _growth['level'] ?? ''}',
              ),
            ),
            if (c.account?.isAdministrator == true) ...[
              OutlinedButton(
                onPressed: () => widget.onGo('/admin'),
                child: const SiteText('内容管理'),
              ),
              OutlinedButton(
                onPressed: () => widget.onGo('/terminal'),
                child: const SiteText('管理终端'),
              ),
            ],
          ],
        ),
      ],
    ),
  );
  Widget _security() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      NativeSiteSection(
        title: '密码安全',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final entry in {
              '当前密码': _currentPassword,
              '新密码': _newPassword,
              '确认新密码': _confirmPassword,
            }.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: entry.value,
                  obscureText: true,
                  enabled: !_saving,
                  decoration: InputDecoration(
                    labelText: siteTranslate(context, entry.key),
                  ),
                ),
              ),
            FilledButton(
              onPressed: _saving || _loading ? null : _password,
              child: const SiteText('更新密码'),
            ),
            if (_profile['has_real_email'] == true ||
                _profile['has_real_email'] == 1)
              TextButton(
                onPressed: _saving
                    ? null
                    : () => widget.onGo(
                        '/login?forgot=1&redirect=%2Fuser-center',
                      ),
                child: const SiteText('没有当前密码？使用邮箱验证'),
              ),
          ],
        ),
      ),
      NativeSiteSection(
        title: 'QQ 账号',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final account in rowsOf(_profile['oauth_accounts']))
              if (account['provider'] == 'qq') ...[
                Text('已绑定：${textOf(account, 'nickname', 'QQ 用户')}'),
                Text('绑定时间：${dateText(account['created_at'])}'),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          if (!await _confirm(
                            '解绑 QQ',
                            '解绑后可继续使用邮箱和密码登录。请在当前密码框输入密码以确认。',
                          )) {
                            return;
                          }
                          await _write('POST', '/api/auth/oauth/qq/unlink', {
                            'currentPassword': _currentPassword.text,
                          }, 'QQ 已解绑');
                          _currentPassword.clear();
                        },
                  child: const SiteText('解绑 QQ'),
                ),
              ],
            if (!rowsOf(_profile['oauth_accounts'])
                .any((account) => account['provider'] == 'qq'))
              OutlinedButton(
                onPressed: () async {
                  if (await showNativeQQBinding(context, c) && mounted) {
                    await _load();
                  }
                },
                child: const SiteText('绑定 QQ 账号'),
              ),
          ],
        ),
      ),
    ],
  );
  List<Map<String, dynamic>> get _filtered {
    final search = _search.text.trim().toLowerCase();
    return (_content[_tab] ?? [])
        .where(
          (row) =>
              search.isEmpty ||
              [
                'title',
                'content',
                'category',
                'description',
                'article_title',
                'status',
              ].any((key) => textOf(row, key).toLowerCase().contains(search)),
        )
        .toList();
  }

  Widget _list() {
    final rows = _filtered,
        pages = ((rows.length + 9) ~/ 10).clamp(1, 100000),
        page = _page.clamp(1, pages);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() => _page = 1),
                decoration: InputDecoration(
                  labelText: siteTranslate(context, '搜索我的内容'),
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            if (_tab == 'articles')
              TextButton(
                onPressed: () => widget.onGo('/editor'),
                child: const SiteText('写文章'),
              ),
            if (_tab == 'pixel')
              TextButton(
                onPressed: () => widget.onGo('/pixel'),
                child: const SiteText('创作像素画'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        for (final row in rows.skip((page - 1) * 10).take(10))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _tab == 'messages'
                        ? textOf(row, 'article_title', '月读广场')
                        : textOf(row, 'title', '未命名'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_tab == 'messages') ...[
                    const SizedBox(height: 8),
                    SelectableText(textOf(row, 'content')),
                  ],
                  if (_tab == 'pixel')
                    SizedBox(height: 180, child: HubPixelPreview(artwork: row)),
                  const SizedBox(height: 8),
                  Text(
                    '${textOf(row, 'status')} · ${dateText(row['created_at'])}',
                  ),
                  Wrap(
                    children: [
                      TextButton(
                        onPressed: () => widget.onGo(
                          _tab == 'pixel'
                              ? '/pixel?art=${row['id']}#pixel-art-${row['id']}'
                              : _tab == 'messages'
                              ? row['article_id'] != null
                                    ? '/articles/${row['article_id']}#comment-${row['id']}'
                                    : '/plaza#msg-${row['id']}'
                              : '/articles/${row['id']}${textOf(row, 'slug').isEmpty ? '' : '/${Uri.encodeComponent(textOf(row, 'slug'))}'}',
                        ),
                        child: const SiteText('查看'),
                      ),
                      if (_tab == 'articles' || _tab == 'pixel')
                        TextButton(
                          onPressed: () => widget.onGo(
                            _tab == 'articles'
                                ? '/editor?id=${row['id']}'
                                : '/pixel?edit=${row['id']}',
                          ),
                          child: const SiteText('编辑'),
                        ),
                      if (_tab == 'messages')
                        TextButton(
                          onPressed: _saving ? null : () => _editMessage(row),
                          child: const SiteText('编辑'),
                        ),
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () async {
                                if (!await _confirm(
                                  _tab == 'bookmarks' ? '取消收藏' : '删除内容',
                                  _tab == 'bookmarks'
                                      ? '确定取消收藏这篇文章？'
                                      : '确定删除这条内容？此操作无法撤销。',
                                )) {
                                  return;
                                }
                                final path = switch (_tab) {
                                  'articles' =>
                                    '/api/user/articles/${row['id']}',
                                  'messages' => '/api/messages/${row['id']}',
                                  'pixel' => '/api/pixel-art/${row['id']}',
                                  _ => '/api/user/bookmarks/${row['id']}',
                                };
                                await _write(
                                  'DELETE',
                                  path,
                                  null,
                                  _tab == 'bookmarks' ? '已取消收藏' : '已删除',
                                );
                              },
                        child: Text(_tab == 'bookmarks' ? '取消收藏' : '删除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (rows.isEmpty && !_loading)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: SiteText('暂无内容')),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: page > 1
                  ? () => setState(() => _page = page - 1)
                  : null,
              child: const SiteText('上一页'),
            ),
            Text('$page / $pages · 共 ${rows.length} 条'),
            TextButton(
              onPressed: page < pages
                  ? () => setState(() => _page = page + 1)
                  : null,
              child: const SiteText('下一页'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '个人中心',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error.isNotEmpty)
          nativeSiteFeedback(context, _error, error: true, retry: _load),
        if (_notice.isNotEmpty) nativeSiteFeedback(context, _notice),
        if (_loading) const LinearProgressIndicator(),
        if (!loggedIn)
          NativeSiteSection(
            title: '登录后管理你的内容',
            child: FilledButton(
              onPressed: () async {
                await showSiteLogin(context, c);
                if (mounted) await _load();
              },
              child: const SiteText('登录'),
            ),
          )
        else ...[
          const SizedBox(height: 16),
          SiteCard(
            child: Wrap(
              spacing: 20,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SiteAvatar(
                  value: textOf(_profile, 'avatar'),
                  name: userDisplayName(
                    _profile,
                    fallback: c.account!.displayName,
                  ),
                  site: c.settings.siteUrl,
                  size: 88,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userDisplayName(
                        _profile,
                        fallback: c.account!.displayName,
                      ),
                      style: const TextStyle(fontSize: 32),
                    ),
                    Text(textOf(_profile, 'bio', '记录你的月下旅程')),
                  ],
                ),
                TextButton(
                  onPressed: _saving || _loading ? null : _avatar,
                  child: const SiteText('上传头像'),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          try {
                            await c.logout();
                          } catch (e) {
                            if (mounted) setState(() => _error = '$e');
                          }
                        },
                  child: const SiteText('退出登录'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const {
                'profile': '个人资料',
                'articles': '我的文章',
                'messages': '我的留言',
                'bookmarks': '我的收藏',
                'pixel': '像素作品',
                'security': '账号安全',
              }.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _tab == entry.key,
                  onSelected: _saving
                      ? null
                      : (_) {
                          setState(() {
                            _tab = entry.key;
                            _page = 1;
                            _search.clear();
                            _notice = '';
                          });
                          _load();
                        },
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (_tab == 'profile')
            _profileView()
          else if (_tab == 'security')
            _security()
          else
            _list(),
        ],
      ],
    ),
  );
}
