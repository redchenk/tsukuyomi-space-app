import '../../core/site_localization.dart';

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'hub_pixel_preview.dart';
import 'login_dialog.dart';
import 'native_auth_page.dart';
import 'native_gallery_details.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';
import 'user_center_copy.dart';

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

class _UserCenterPageState extends State<UserCenterPage>
    with WidgetsBindingObserver {
  RoomController get c => widget.controller;
  String get _accountScope =>
      '${endpointUri(c.settings.siteUrl).origin}:${c.account?.id ?? 'guest'}';
  String _scope = '', _tab = 'profile', _error = '', _notice = '';
  int _epoch = 0, _page = 1;
  bool _loading = true, _saving = false;
  Map<String, dynamic> _profile = {}, _growth = {};
  final _navigationSearch = TextEditingController();
  final _contentPanelKey = GlobalKey();
  final _contentFocus = FocusNode();
  final _loadingTabs = <String>{};
  final _panelErrors = <String, String>{};
  DateTime? _lastArticleRefresh;
  bool _syncingProfile = false;
  bool? _routeCurrent;
  String _copy(String key) => userCenterCopy(context, key);
  bool get _profileDirty =>
      _nickname.text !=
          userDisplayName(_profile, fallback: c.account?.displayName ?? '') ||
      _bio.text != textOf(_profile, 'bio');
  bool get _refreshing => _loading || _loadingTabs.isNotEmpty;
  void _profileEdited() {
    if (mounted && !_syncingProfile) setState(() {});
  }

  void _resetProfile({bool clearNotice = true}) {
    _syncingProfile = true;
    _nickname.text = userDisplayName(
      _profile,
      fallback: c.account?.displayName ?? '',
    );
    _bio.text = textOf(_profile, 'bio');
    _syncingProfile = false;
    if (mounted && clearNotice) setState(() => _notice = '');
  }

  Future<void> _refreshAccount() async {
    if (!_profileDirty && !_saving && !_refreshing) await _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.isCurrentOf(context) ?? true;
    if (_routeCurrent == false && current && _tab == 'articles') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && loggedIn) _loadContent('articles');
      });
    }
    _routeCurrent = current;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _tab == 'articles' &&
        loggedIn &&
        (_lastArticleRefresh == null ||
            DateTime.now().difference(_lastArticleRefresh!) >=
                const Duration(milliseconds: 1500))) {
      _loadContent('articles');
    }
  }

  int get _growthLevel {
    final summary = mapOf(_growth['summary']);
    final raw = summary['level'] ?? _growth['level'];
    final value = raw is Map ? raw['level'] : raw;
    return (value is num ? value.toInt() : int.tryParse('$value') ?? 1).clamp(
      1,
      9,
    );
  }

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
    WidgetsBinding.instance.addObserver(this);
    _nickname.addListener(_profileEdited);
    _bio.addListener(_profileEdited);
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
      _loadingTabs.clear();
      _panelErrors.clear();
      _lastArticleRefresh = null;
      _navigationSearch.clear();
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
    WidgetsBinding.instance.removeObserver(this);
    _navigationSearch.dispose();
    _contentFocus.dispose();
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

  Future<void> _load({bool resetProfile = false}) async {
    final keepProfileEdits =
        _profile.isNotEmpty && _profileDirty && !resetProfile;
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
      setState(() => _profile = profile);
      if (!keepProfileEdits) _resetProfile(clearNotice: false);
      await Future.wait([
        () async {
          try {
            final growth = mapOf(
              (await _request('GET', '/api/growth/me'))['data'],
            );
            if (mounted && epoch == _epoch && scope == _accountScope) {
              setState(() => _growth = growth);
            }
          } catch (_) {
            if (mounted && epoch == _epoch && scope == _accountScope) {
              setState(() => _growth = {});
            }
          }
        }(),
        for (final tab in ['articles', 'messages', 'bookmarks', 'pixel'])
          _loadContent(tab),
      ]);
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

  Future<void> _loadContent(String tab) async {
    if (!loggedIn || _loadingTabs.contains(tab)) return;
    final scope = _accountScope, epoch = _epoch;
    setState(() {
      _loadingTabs.add(tab);
      _panelErrors.remove(tab);
    });
    if (tab == 'articles') _lastArticleRefresh = DateTime.now();
    try {
      final path = switch (tab) {
        'articles' =>
          '/api/user/articles/live/${DateTime.now().microsecondsSinceEpoch}',
        'messages' => '/api/messages/mine?limit=100',
        'bookmarks' => '/api/user/bookmarks?limit=80',
        'pixel' => '/api/pixel-art/manage?limit=100',
        _ => throw ArgumentError.value(tab),
      };
      final result = await _request('GET', path);
      if (result['success'] == false) {
        throw ApiFailure(textOf(result, 'message', '加载失败'));
      }
      final data = result['data'];
      if (mounted && scope == _accountScope && epoch == _epoch) {
        setState(
          () => _content[tab] = rowsOf(
            data is List ? data : mapOf(data)['items'],
          ),
        );
      }
    } catch (e) {
      if (mounted && scope == _accountScope && epoch == _epoch) {
        setState(() => _panelErrors[tab] = '$e');
      }
    } finally {
      if (mounted && scope == _accountScope && epoch == _epoch) {
        setState(() => _loadingTabs.remove(tab));
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
    if (_saving || _loading || _loadingTabs.contains(_tab)) return;
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
      if (reload) {
        if (_tab == 'profile' || _tab == 'security') {
          await _load(
            resetProfile: method == 'PUT' && path == '/api/user/profile',
          );
        } else {
          await _loadContent(_tab);
        }
      }
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
    final scope = _accountScope;
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
    if (mounted && scope == _accountScope && _error.isEmpty) {
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

  Widget _profileView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionHeading(
        '个人资料',
        Icons.person_outline,
        subtitle: _copy('profileHint'),
      ),
      TextField(
        key: const Key('account-nickname'),
        controller: _nickname,
        enabled: !_saving && !_loading,
        decoration: InputDecoration(labelText: siteTranslate(context, '昵称')),
      ),
      const SizedBox(height: 8),
      SiteText(
        '1–32 个字符，可随时修改、可重名，不影响登录账号。',
        style: TextStyle(fontSize: 11, color: RoomStyle(context).muted),
      ),
      const SizedBox(height: 22),
      TextField(
        key: const Key('account-bio'),
        controller: _bio,
        enabled: !_saving && !_loading,
        maxLines: 4,
        maxLength: 300,
        decoration: InputDecoration(labelText: siteTranslate(context, '个人简介')),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _profileDirty ? Icons.edit_outlined : Icons.check,
                size: 15,
                color: RoomStyle(context).muted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _copy(_profileDirty ? 'unsaved' : 'saved'),
                  style: TextStyle(
                    fontSize: 11,
                    color: RoomStyle(context).muted,
                  ),
                ),
              ),
            ],
          ),
          OutlinedButton(
            key: const Key('account-reset-profile'),
            onPressed: !_profileDirty || _saving ? null : _resetProfile,
            child: Text(_copy('discard')),
          ),
          FilledButton.icon(
            key: const Key('account-save-profile'),
            onPressed:
                !_profileDirty ||
                    _saving ||
                    _loading ||
                    nicknameError(_nickname.text) != null
                ? null
                : () => _write('PUT', '/api/user/profile', {
                    'bio': _bio.text,
                    'nickname': _nickname.text.trim(),
                  }, '个人资料已保存'),
            icon: const Icon(Icons.check, size: 17),
            label: const SiteText('保存资料'),
          ),
        ],
      ),
      const SizedBox(height: 28),
      const Divider(height: 1),
      ExpansionTile(
        key: const Key('account-information'),
        tilePadding: EdgeInsets.zero,
        title: Text(_copy('accountInfo'), style: const TextStyle(fontSize: 12)),
        children: [
          for (final field in [
            ('登录用户名', textOf(_profile, 'username')),
            ('用户 ID（不可修改）', textOf(_profile, 'id')),
            ('邮箱', textOf(_profile, 'email', '未绑定邮箱')),
            ('加入时间', dateText(_profile['created_at'])),
            ('账户角色', siteTranslate(context, _roleLabel)),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SiteText(
                    field.$1,
                    style: TextStyle(
                      fontSize: 11,
                      color: RoomStyle(context).muted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    field.$2,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
      if (c.account?.isAdministrator == true)
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            OutlinedButton(
              onPressed: () => widget.onGo('/admin'),
              child: const SiteText('内容管理'),
            ),
            OutlinedButton(
              onPressed: () => widget.onGo('/terminal'),
              child: const SiteText('管理终端'),
            ),
          ],
        ),
    ],
  );

  Widget _sectionHeading(
    String title,
    IconData icon, {
    String? subtitle,
    bool translate = true,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SiteText(
                  title,
                  translate: translate,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 7),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.7,
                      color: RoomStyle(context).muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, color: RoomStyle(context).accent, size: 24),
        ],
      ),
      const SizedBox(height: 22),
      const Divider(height: 1),
      const SizedBox(height: 24),
    ],
  );
  Widget _security() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionHeading('账户安全', Icons.shield_outlined),
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
                          final scope = _accountScope;
                          if (!await _confirm(
                            '解绑 QQ',
                            '解绑后可继续使用邮箱和密码登录。请在当前密码框输入密码以确认。',
                          )) {
                            return;
                          }
                          if (!mounted || scope != _accountScope || !loggedIn) {
                            return;
                          }
                          await _write('POST', '/api/auth/oauth/qq/unlink', {
                            'currentPassword': _currentPassword.text,
                          }, 'QQ 已解绑');
                          if (mounted && scope == _accountScope) {
                            _currentPassword.clear();
                          }
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
        _sectionHeading(_tabLabel(_tab), _tabs[_tab]!.$2, translate: false),
        TextField(
          key: const Key('account-content-search'),
          controller: _search,
          onChanged: (_) => setState(() => _page = 1),
          decoration: InputDecoration(
            labelText: _tab == 'articles'
                ? siteTr(context, 'ucSearchArticles')
                : siteTranslate(context, '搜索我的内容'),
            prefixIcon: const Icon(Icons.search),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            OutlinedButton.icon(
              key: const Key('account-content-refresh'),
              onPressed: _saving || _loadingTabs.contains(_tab)
                  ? null
                  : () => _loadContent(_tab),
              icon: const Icon(Icons.refresh, size: 17),
              label: Text(
                _tab == 'articles'
                    ? _copy('refreshArticles')
                    : siteTranslate(context, '刷新'),
              ),
            ),
            if (_tab == 'articles')
              FilledButton.icon(
                onPressed: () => widget.onGo('/editor'),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const SiteText('写文章'),
              ),
            if (_tab == 'pixel')
              FilledButton.icon(
                onPressed: () => widget.onGo('/pixel'),
                icon: const Icon(Icons.palette_outlined, size: 17),
                label: const SiteText('创作像素画'),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_loadingTabs.contains(_tab)) const LinearProgressIndicator(),
        if (_panelErrors[_tab] case final String error)
          nativeSiteFeedback(
            context,
            error,
            error: true,
            retry: () => _loadContent(_tab),
          ),
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
                      fontSize: 15,
                      height: 1.7,
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
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: RoomStyle(context).selected,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _tab == 'bookmarks'
                              ? 'bookmarked'
                              : textOf(row, 'status', 'published'),
                          style: TextStyle(
                            fontSize: 11,
                            color: RoomStyle(context).muted,
                          ),
                        ),
                      ),
                      if (textOf(row, 'category').isNotEmpty)
                        Text(
                          textOf(row, 'category'),
                          style: TextStyle(
                            fontSize: 11,
                            color: RoomStyle(context).muted,
                          ),
                        ),
                      if (_tab == 'articles')
                        Text(
                          '${siteTr(context, 'ucReading')} ${row['view_count'] ?? 0}',
                          style: TextStyle(
                            fontSize: 11,
                            color: RoomStyle(context).muted,
                          ),
                        ),
                      Text(
                        dateText(
                          _tab == 'bookmarks'
                              ? row['bookmarked_at']
                              : row['created_at'],
                        ),
                        style: TextStyle(
                          fontSize: 11,
                          color: RoomStyle(context).muted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
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
                          onPressed: _saving || _loadingTabs.contains(_tab)
                              ? null
                              : () => _editMessage(row),
                          child: const SiteText('编辑'),
                        ),
                      TextButton(
                        onPressed: _saving || _loadingTabs.contains(_tab)
                            ? null
                            : () async {
                                final scope = _accountScope, tab = _tab;
                                if (!await _confirm(
                                  _tab == 'bookmarks' ? '取消收藏' : '删除内容',
                                  _tab == 'bookmarks'
                                      ? '确定取消收藏这篇文章？'
                                      : '确定删除这条内容？此操作无法撤销。',
                                )) {
                                  return;
                                }
                                if (!mounted ||
                                    scope != _accountScope ||
                                    tab != _tab ||
                                    !loggedIn) {
                                  return;
                                }
                                final path = switch (tab) {
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
        if (rows.isEmpty &&
            !_loading &&
            !_loadingTabs.contains(_tab) &&
            !_panelErrors.containsKey(_tab))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 12),
            child: Column(
              children: [
                Text(
                  _search.text.trim().isNotEmpty
                      ? _copy('noMatches')
                      : _tab == 'articles'
                      ? siteTr(context, 'ucNoArticles')
                      : siteTranslate(context, '暂无内容'),
                  textAlign: TextAlign.center,
                ),
                if (_tab == 'articles' && _search.text.trim().isEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    siteTr(context, 'ucNoArticlesHint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: RoomStyle(context).muted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => widget.onGo('/editor'),
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const SiteText('新建投稿'),
                  ),
                ],
                if (_search.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    _copy('searchHint'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: RoomStyle(context).muted,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _search.clear();
                      _page = 1;
                    }),
                    child: Text(_copy('clearSearch')),
                  ),
                ],
              ],
            ),
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

  String get _roleLabel => c.account?.isAdministrator == true ? '管理员' : '普通用户';

  Future<void> _logout() async {
    try {
      await c.logout();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Widget _hero() => SiteCard(
    padding: const EdgeInsets.all(22),
    child: LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final mobile = box.maxWidth < 660 * scale;
        final compact = box.maxWidth < 1090 * scale;
        final avatarSize = mobile
            ? 56.0
            : compact
            ? 68.0
            : 76.0;
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mobile) ...[
              Text(
                'YOUR SPACE',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.6,
                  color: RoomStyle(context).muted,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  userDisplayName(_profile, fallback: c.account!.displayName),
                  style: TextStyle(
                    fontSize: mobile ? 23 : 30,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_growth.isNotEmpty)
                  TextButton(
                    key: const Key('account-growth-link'),
                    onPressed: () => widget.onGo('/growth'),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(44, 36),
                      alignment: Alignment.centerLeft,
                    ),
                    child: NativeUserLevelBadge(level: _growthLevel),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            SiteText(
              textOf(_profile, 'bio').isEmpty
                  ? '还没有个人简介。'
                  : textOf(_profile, 'bio'),
              translate: textOf(_profile, 'bio').isEmpty,
              style: TextStyle(
                fontSize: 13,
                height: 1.7,
                color: RoomStyle(context).muted,
              ),
            ),
            const SizedBox(height: 14),
            _statistics(),
          ],
        );
        final avatar = Tooltip(
          message: _copy('avatarHint'),
          child: InkWell(
            key: const Key('account-upload-avatar'),
            onTap: _saving || _loading ? null : _avatar,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: avatarSize + 4,
              height: avatarSize + 4,
              child: Stack(
                children: [
                  SiteAvatar(
                    value: textOf(_profile, 'avatar'),
                    name: userDisplayName(
                      _profile,
                      fallback: c.account!.displayName,
                    ),
                    site: c.settings.siteUrl,
                    size: avatarSize,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 27,
                      height: 27,
                      decoration: BoxDecoration(
                        color: RoomStyle(context).accent,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.surface,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.edit_outlined,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        final actions = Wrap(
          spacing: 10,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.onGo(
                '/users/${Uri.encodeComponent(textOf(_profile, 'username'))}',
              ),
              icon: const Icon(Icons.person_outline, size: 17),
              label: Text(_copy('publicProfile')),
            ),
            FilledButton.icon(
              onPressed: () => widget.onGo('/editor'),
              icon: const Icon(Icons.edit_outlined, size: 17),
              label: const SiteText('新建投稿'),
            ),
            IconButton.outlined(
              key: const Key('account-refresh'),
              tooltip: _copy('refresh'),
              onPressed: _refreshing || _saving || _profileDirty
                  ? null
                  : _refreshAccount,
              icon: const Icon(Icons.refresh, size: 17),
            ),
          ],
        );
        return compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      avatar,
                      SizedBox(width: mobile ? 12 : 24),
                      Expanded(child: info),
                    ],
                  ),
                  const SizedBox(height: 16),
                  actions,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  avatar,
                  const SizedBox(width: 24),
                  Expanded(child: info),
                  const SizedBox(width: 24),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 350 * scale),
                    child: actions,
                  ),
                ],
              );
      },
    ),
  );

  Widget _statistics() {
    final articles = _content['articles'] ?? [];
    final totalViews = articles.fold<int>(
      0,
      (sum, row) =>
          sum +
          (row['view_count'] is num
              ? (row['view_count'] as num).toInt()
              : int.tryParse('${row['view_count']}') ?? 0),
    );
    return Wrap(
      spacing: 24,
      runSpacing: 8,
      children: [
        for (final stat in [
          ('我的文章', '${articles.length}'),
          ('累计阅读', '$totalViews'),
          (_copy('bookmarks'), '${(_content['bookmarks'] ?? []).length}'),
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: SiteText(
                  stat.$1,
                  style: TextStyle(
                    fontSize: 12,
                    color: RoomStyle(context).muted,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Text(
                stat.$2,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
      ],
    );
  }

  static const _tabs = {
    'profile': ('个人资料', Icons.person_outline),
    'security': ('账户安全', Icons.shield_outlined),
    'articles': ('我的文章', Icons.article_outlined),
    'messages': ('我的留言', Icons.forum_outlined),
    'bookmarks': ('我的收藏', Icons.bookmark_border),
    'pixel': ('像素画', Icons.palette_outlined),
    '/gallery/manage': ('图库管理', Icons.photo_library_outlined),
    '/attachments': ('附件库', Icons.attach_file),
  };
  String _tabLabel(String key) => switch (key) {
    'profile' => siteTr(context, 'ucProfile'),
    'security' => siteTr(context, 'ucSecurity'),
    'articles' => siteTr(context, 'ucArticlesTab'),
    'messages' => _copy('messages'),
    'bookmarks' => _copy('bookmarks'),
    'pixel' => _copy('pixels'),
    '/gallery/manage' => _copy('gallery'),
    '/attachments' => _copy('attachments'),
    _ => key,
  };
  static const _keywords = {
    'profile': 'profile nickname 资料 昵称',
    'security': 'security password email 安全 密码 邮箱 QQ',
    'articles': 'articles posts 文章',
    'messages': 'messages replies 留言 评论 回复',
    'bookmarks': 'bookmarks 收藏',
    'pixel': 'pixel art 像素画',
    '/gallery/manage': 'gallery 图库 图片',
    '/attachments': 'attachments files 附件 文件',
  };

  void _selectTab(String key, {bool focusContent = false}) {
    if (_saving) return;
    if (key.startsWith('/')) {
      widget.onGo(key);
      return;
    }
    setState(() {
      _tab = key;
      _page = 1;
      _search.clear();
      _notice = '';
    });
    if (key != 'profile' && key != 'security') _loadContent(key);
    if (focusContent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final panel = _contentPanelKey.currentContext;
        if (panel != null) {
          Scrollable.ensureVisible(panel, duration: Duration.zero);
        }
        _contentFocus.requestFocus();
      });
    }
  }

  Widget _navigation() {
    final query = _navigationSearch.text.trim().toLowerCase();
    final groups = [
      ('account', ['profile', 'security']),
      ('creative', ['articles', 'messages', 'bookmarks', 'pixel']),
      ('materials', ['/gallery/manage', '/attachments']),
    ];
    final visible = groups
        .map(
          (group) => (
            group.$1,
            group.$2
                .where(
                  (key) =>
                      query.isEmpty ||
                      '${_copy(group.$1)} ${_tabLabel(key)} ${_keywords[key]}'
                          .toLowerCase()
                          .contains(query),
                )
                .toList(),
          ),
        )
        .where((group) => group.$2.isNotEmpty)
        .toList();
    return SiteCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('account-navigation-search'),
            controller: _navigationSearch,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              hintText: _copy('search'),
              prefixIcon: const Icon(Icons.search, size: 16),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 22),
          for (final group in visible) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                _copy(group.$1),
                style: TextStyle(fontSize: 11, color: RoomStyle(context).muted),
              ),
            ),
            const SizedBox(height: 5),
            for (final key in group.$2)
              ListTile(
                key: ValueKey('account-tab-$key'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                minLeadingWidth: 18,
                horizontalTitleGap: 10,
                dense: true,
                selected: _tab == key,
                selectedTileColor: RoomStyle(context).selected,
                shape: const StadiumBorder(),
                leading: Icon(_tabs[key]!.$2, size: 18),
                title: SiteText(
                  _tabs[key]!.$1,
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: key.startsWith('/')
                    ? const Icon(Icons.chevron_right, size: 14)
                    : _content.containsKey(key)
                    ? Text(
                        '${_content[key]!.length}',
                        style: const TextStyle(fontSize: 10),
                      )
                    : null,
                onTap: _saving ? null : () => _selectTab(key),
              ),
            const SizedBox(height: 20),
          ],
          if (visible.isEmpty) ...[
            Text(
              _copy('noSections'),
              style: TextStyle(color: RoomStyle(context).muted, fontSize: 12),
            ),
            TextButton(
              onPressed: () => setState(() => _navigationSearch.clear()),
              child: Text(_copy('clearSearch')),
            ),
          ],
          const Divider(),
          TextButton.icon(
            onPressed: _saving ? null : _logout,
            icon: const Icon(Icons.logout, size: 17),
            label: const SiteText('退出登录'),
          ),
        ],
      ),
    );
  }

  Widget _mobileNavigation() => LayoutBuilder(
    builder: (context, box) {
      final select = DropdownButtonFormField<String>(
        key: const Key('account-mobile-section'),
        initialValue: _tab,
        isExpanded: true,
        itemHeight: null,
        decoration: InputDecoration(
          labelText: _copy('navigation'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 15,
            vertical: 10,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(999)),
        ),
        items: [
          for (final entry in _tabs.entries.where(
            (entry) => !entry.key.startsWith('/'),
          ))
            DropdownMenuItem(
              value: entry.key,
              child: Text(
                _tabLabel(entry.key),
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
        onChanged: _saving
            ? null
            : (key) {
                if (key != null) _selectTab(key);
              },
      );
      final more = PopupMenuButton<String>(
        key: const Key('account-mobile-materials'),
        tooltip: _copy('materials'),
        onSelected: (value) =>
            value == 'logout' ? _logout() : _selectTab(value),
        itemBuilder: (_) => [
          for (final key in ['/gallery/manage', '/attachments'])
            PopupMenuItem(
              value: key,
              child: Row(
                children: [
                  Icon(_tabs[key]!.$2, size: 17),
                  const SizedBox(width: 10),
                  Text(_tabLabel(key)),
                ],
              ),
            ),
          const PopupMenuItem(
            value: 'logout',
            child: Row(
              children: [
                Icon(Icons.logout, size: 17),
                SizedBox(width: 10),
                SiteText('退出登录'),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(color: RoomStyle(context).line),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _copy('materials'),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_more, size: 15),
            ],
          ),
        ),
      );
      if (box.maxWidth < 360 * MediaQuery.textScalerOf(context).scale(1)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            select,
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: more),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: select),
          const SizedBox(width: 10),
          more,
        ],
      );
    },
  );

  Widget _supportCard(String title, IconData icon, List<Widget> children) =>
      SiteCard(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 19, color: RoomStyle(context).accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      );
  Widget _supportAction(String key, String label, VoidCallback action) =>
      OutlinedButton(
        key: Key(key),
        onPressed: action,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
            const SizedBox(width: 6),
            const Icon(Icons.arrow_forward, size: 16),
          ],
        ),
      );
  Widget _growthSupport() {
    final level = mapOf(_growth['level']);
    final raw = level['progressPercent'];
    final progress =
        ((raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0) / 100)
            .clamp(0.0, 1.0);
    return _supportCard(_copy('growth'), Icons.auto_awesome_outlined, [
      if (_growth.isNotEmpty) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: NativeUserLevelBadge(level: _growthLevel),
        ),
        const SizedBox(height: 20),
        LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          borderRadius: BorderRadius.circular(999),
          semanticsLabel: _copy('growth'),
        ),
        const SizedBox(height: 9),
        Text(
          _growthLevel == 9
              ? _copy('maxLevel')
              : level['requiredXp'] != null
              ? '${level['progressXp'] ?? 0} / ${level['requiredXp']} ${_copy('xp')}'
              : level['totalXp'] != null
              ? '${level['totalXp']} ${_copy('xp')}'
              : _copy('growthHint'),
          style: TextStyle(fontSize: 11, color: RoomStyle(context).muted),
        ),
        const SizedBox(height: 22),
      ] else ...[
        Text(
          _copy('growthUnavailable'),
          style: TextStyle(fontSize: 12, color: RoomStyle(context).muted),
        ),
        const SizedBox(height: 16),
      ],
      _supportAction(
        'account-growth-tasks',
        _copy('growthOpen'),
        () => widget.onGo('/growth'),
      ),
    ]);
  }

  Widget _securitySupport() => _supportCard(
    _copy('security'),
    Icons.shield_outlined,
    [
      for (final item in [
        (
          'email',
          _profile['has_real_email'] == true || _profile['has_real_email'] == 1,
        ),
        (
          'qq',
          rowsOf(_profile['oauth_accounts'])
              .any((row) => row['provider'] == 'qq'),
        ),
      ])
        Container(
          key: ValueKey('account-binding-${item.$1}'),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: RoomStyle(context).selected,
            border: Border.all(color: RoomStyle(context).line),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 10,
            runSpacing: 6,
            children: [
              Text(
                _copy(item.$1),
                style: TextStyle(fontSize: 12, color: RoomStyle(context).muted),
              ),
              Text(
                _copy(item.$2 ? 'linked' : 'unlinked'),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      const SizedBox(height: 12),
      _supportAction(
        'account-open-security',
        _copy('securityOpen'),
        () => _selectTab('security', focusContent: true),
      ),
    ],
  );
  Widget _roomSupport() => SiteCard(
    padding: const EdgeInsets.all(22),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.nightlight_outlined,
          size: 24,
          color: RoomStyle(context).accent,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _copy('room'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _copy('roomHint'),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.8,
                  color: RoomStyle(context).muted,
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => widget.onGo('/room'),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_copy('roomOpen'))),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward, size: 15),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _support({bool columns = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (columns)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _growthSupport()),
            const SizedBox(width: 16),
            Expanded(child: _securitySupport()),
          ],
        )
      else ...[
        _growthSupport(),
        const SizedBox(height: 16),
        _securitySupport(),
      ],
      const SizedBox(height: 16),
      _roomSupport(),
    ],
  );

  Widget _panels() => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
      final mobile = box.maxWidth < 656 * scale;
      final wide = box.maxWidth >= 1086 * scale;
      final content = Focus(
        key: _contentPanelKey,
        focusNode: _contentFocus,
        child: SiteCard(
          padding: EdgeInsets.all(mobile ? 20 : 28),
          child: _tab == 'profile'
              ? _profileView()
              : _tab == 'security'
              ? _security()
              : _list(),
        ),
      );
      if (mobile) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _mobileNavigation(),
            const SizedBox(height: 16),
            content,
            const SizedBox(height: 16),
            _support(),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: wide ? 210 : 190, child: _navigation()),
          SizedBox(width: wide ? 22 : 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                content,
                if (!wide) ...[
                  const SizedBox(height: 18),
                  _support(columns: box.maxWidth >= 850 * scale),
                ],
              ],
            ),
          ),
          if (wide) ...[
            const SizedBox(width: 22),
            SizedBox(width: 250, child: _support()),
          ],
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '个人中心',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _refreshAccount,
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
          _hero(),
          const SizedBox(height: 24),
          _panels(),
        ],
      ],
    ),
  );
}
