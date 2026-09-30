import '../../core/site_localization.dart';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'login_dialog.dart';
import 'management_service.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

const _panels = <String, String>{
  'dashboard': '总览',
  'analytics': '访问统计',
  'articles': '文章',
  'messages': '留言审核',
  'gallery': '画廊',
  'attachments': '附件',
  'links': '友链审核',
  'users': '用户',
  'account': '账号安全',
  'notifications': '通知设置',
  'settings': '站点设置',
};
const _siteFields = <String, String>{
  'siteTitle': '站点标题',
  'siteAnnouncement': '站点公告',
  'sakuraEffect': '樱花效果',
  'scanlineEffect': '扫描线效果',
  'visitPopupEnabled': '访问欢迎弹窗',
  'visitPopupTitle': '欢迎标题',
  'visitPopupContent': '欢迎内容',
  'visitPopupButton': '欢迎按钮文字',
  'messageReviewKeywords': '留言审核关键词',
  'beianText': 'ICP备案号',
  'beianUrl': 'ICP备案链接',
  'mpsBeianText': '公安备案号',
  'mpsBeianUrl': '公安备案链接',
  'mpsBeianIcon': '公安备案图标',
};
const _ossFields = <String, String>{
  'ossEnabled': '启用对象存储',
  'ossProvider': '存储提供商',
  'ossEndpoint': '服务端点',
  'ossRegion': '区域',
  'ossBucket': '存储桶',
  'ossAccessKeyId': 'Access Key ID',
  'ossAccessKeySecret': 'Access Key Secret',
  'ossPublicBaseUrl': '公开访问地址',
  'ossPrefix': '对象前缀',
  'ossUploadPath': '上传目录模板',
  'ossDefaultStorage': '默认存储位置',
  'ossFileNameMode': '文件命名方式',
  'ossForcePathStyle': '使用路径模式',
};
const _booleanFields = {
  'sakuraEffect',
  'scanlineEffect',
  'visitPopupEnabled',
  'ossEnabled',
  'ossForcePathStyle',
  'emailNotifyReplies',
  'emailNotifyLikes',
  'emailNotifyUnusualLogin',
};

class ManagementPage extends StatefulWidget {
  const ManagementPage({
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
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  RoomController get c => widget.controller;
  String get _accountScope =>
      '${endpointUri(c.settings.siteUrl).origin}:${c.account?.id ?? 'guest'}';
  bool get terminal => Uri.parse(widget.path).path == '/terminal';
  bool _terminalSession = false, _loading = true, _saving = false;
  Map<String, dynamic> _admin = {},
      _values = {},
      _summary = {},
      _preference = {};
  List<Map<String, dynamic>> _rows = [], _categories = [];
  String _panel = 'articles', _error = '', _notice = '', _status = 'all';
  String _scope = '';
  int _epoch = 0, _page = 1, _totalPages = 1, _total = 0;
  final _search = TextEditingController(),
      _username = TextEditingController(),
      _password = TextEditingController();
  final Map<String, TextEditingController> _fields = {};
  ManagementService get api => ManagementService(
    c.site as SiteDataService,
    c.settings.siteUrl,
    terminalSession: _terminalSession,
  );
  bool get superAdmin => _terminalSession && _admin['role'] == 'super_admin';
  List<String> get panels => !terminal
      ? ['articles', 'messages', 'gallery', 'attachments']
      : _terminalSession
      ? [
          'dashboard',
          'analytics',
          'articles',
          'messages',
          'links',
          'users',
          'account',
          'notifications',
          'settings',
        ]
      : ['articles', 'messages', 'notifications'];

  @override
  void initState() {
    super.initState();
    _scope =
        '$_accountScope:${c.account?.role}:${c.sessionExpired}:${c.loading}';
    c.addListener(_accountChanged);
    _verify();
  }

  void _accountChanged() {
    final identity =
        '$_accountScope:${c.account?.role}:${c.sessionExpired}:${c.loading}';
    if (_scope != identity) {
      _scope = identity;
      _epoch++;
      _admin = {};
      _rows = [];
      _summary = {};
      _categories = [];
      _values = {};
      _preference = {};
      for (final field in _fields.values) {
        field.clear();
      }
      _verify();
    }
  }

  @override
  void dispose() {
    _epoch++;
    c.removeListener(_accountChanged);
    for (final field in [_search, _username, _password, ..._fields.values]) {
      field.dispose();
    }
    super.dispose();
  }

  bool _valid(int epoch, String scope) =>
      mounted && epoch == _epoch && scope == _accountScope;
  Future<void> _verify() async {
    final epoch = ++_epoch, scope = _accountScope;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      if (c.site is! SiteDataService) throw const ApiFailure('站点连接不可用');
      if (c.loading || c.account?.isAdministrator != true || c.sessionExpired) {
        if (_valid(epoch, scope)) setState(() => _admin = {});
        return;
      }
      Map<String, dynamic> admin = {};
      var standalone = false;
      if (terminal &&
          (c.site.cookie ?? '').contains('tsukuyomi_admin_session=')) {
        try {
          final result = await (c.site as SiteDataService).request(
            c.settings.siteUrl,
            'GET',
            '/api/admin/me',
          );
          admin = mapOf(result['data']);
          standalone = true;
        } on ApiFailure catch (e) {
          if (e.status != 401 && e.status != 403) rethrow;
        }
      }
      if (admin.isEmpty && c.account != null && !c.sessionExpired) {
        admin = mapOf(
          (await (c.site as SiteDataService).request(
            c.settings.siteUrl,
            'GET',
            '/api/moderation/me',
          ))['data'],
        );
      }
      if (!_valid(epoch, scope)) return;
      _admin = admin;
      _terminalSession = standalone;
      final requested = Uri.parse(widget.path).queryParameters['panel'];
      _panel = panels.contains(requested)
          ? requested!
          : (standalone ? 'dashboard' : 'articles');
      if (_admin.isNotEmpty) await _load();
    } catch (e) {
      if (_valid(epoch, scope)) setState(() => _error = '$e');
    } finally {
      if (_valid(epoch, scope)) setState(() => _loading = false);
    }
  }

  Future<void> _login() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await c.login(
        '',
        '',
        credentials: {
          'username': _username.text.trim(),
          'password': _password.text,
        },
        authPath: '/api/admin/login',
      );
      _password.clear();
      await _verify();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _load() async {
    if (_admin.isEmpty) return;
    final epoch = ++_epoch, scope = _accountScope, panel = _panel, page = _page;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      dynamic data;
      List<Map<String, dynamic>> categories = [];
      Map<String, dynamic> summary = _summary;
      if (!terminal) summary = mapOf(await api.data('GET', '/summary'));
      if (panel == 'gallery' || panel == 'attachments') {
        final query = Uri(
          queryParameters: {
            'scope': 'all',
            'limit': '12',
            'page': '$page',
            'search': _search.text.trim(),
            if (panel == 'attachments') 'collection': 'attachments',
          },
        ).query;
        data = (await (c.site as SiteDataService).request(
          c.settings.siteUrl,
          'GET',
          '/api/assets${panel == 'gallery' ? '/gallery' : ''}?$query',
        ))['data'];
      } else if (panel == 'articles' || panel == 'messages') {
        final query = !_terminalSession
            ? '?${Uri(queryParameters: {'limit': '10', 'page': '$page', 'search': _search.text.trim(), 'status': _status}).query}'
            : '';
        data = await api.data('GET', '/$panel$query');
        if (panel == 'articles') {
          categories = rowsOf(
            (await api.request('GET', '/article-categories'))['data'],
          );
        }
      } else if (panel == 'dashboard') {
        data = await api.data('GET', '/stats');
      } else if (panel == 'analytics') {
        data = await api.data('GET', '/analytics');
      } else if (panel == 'notifications') {
        data = await api.data('GET', '/notification-preferences');
        if (superAdmin) summary = mapOf(await api.data('GET', '/settings'));
      } else if (panel != 'account') {
        data = await api.data('GET', '/$panel');
      }
      if (!_valid(epoch, scope) || panel != _panel) return;
      setState(() {
        _summary = summary;
        _categories = categories;
        if (data is List) {
          var rows = rowsOf(data);
          final search = _search.text.trim().toLowerCase();
          if (search.isNotEmpty) {
            rows = rows
                .where(
                  (row) => row.values.any(
                    (v) => '$v'.toLowerCase().contains(search),
                  ),
                )
                .toList();
          }
          if (_status != 'all') {
            rows = rows.where((row) => row['status'] == _status).toList();
          }
          _total = rows.length;
          _totalPages = ((_total + 9) ~/ 10).clamp(1, 100000);
          _page = page.clamp(1, _totalPages);
          _rows = rows.skip((_page - 1) * 10).take(10).toList();
        } else {
          final payload = mapOf(data),
              pagination = mapOf(mapOf(data)['pagination']);
          _values = payload;
          _rows = rowsOf(payload['items'] ?? payload['assets']);
          _total = (pagination['total'] as num?)?.toInt() ?? _rows.length;
          _totalPages = ((pagination['totalPages'] as num?)?.toInt() ?? 1)
              .clamp(1, 100000);
        }
        if (panel == 'notifications') {
          _preference = mapOf(data);
          _values = superAdmin ? _summary : {};
        }
        if (panel == 'settings') {
          for (final entry in {
            ..._siteFields,
            if (superAdmin) ..._ossFields,
          }.entries) {
            _field(entry.key).text = textOf(_values, entry.key);
          }
        }
      });
    } catch (e) {
      if (_valid(epoch, scope)) setState(() => _error = '$e');
    } finally {
      if (_valid(epoch, scope)) setState(() => _loading = false);
    }
  }

  TextEditingController _field(String key) =>
      _fields.putIfAbsent(key, TextEditingController.new);
  Future<bool> _confirm(String title, String description) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(description),
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
  Future<Map<String, String>?> _form(
    String title,
    Map<String, String> fields, {
    Set<String> secrets = const {},
  }) async {
    final controllers = fields.map(
      (key, value) => MapEntry(key, TextEditingController(text: value)),
    );
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final field in controllers.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: field.value,
                      obscureText: secrets.contains(field.key),
                      decoration: InputDecoration(labelText: field.key),
                      maxLines: secrets.contains(field.key)
                          ? 1
                          : (field.key.contains('描述') ? 3 : 1),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controllers.map((key, value) => MapEntry(key, value.text)),
            ),
            child: const SiteText('保存'),
          ),
        ],
      ),
    );
    // Dialog routes finish their exit animation before releasing controllers.
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    });
    return result;
  }

  Future<void> _mutate(
    Future<void> Function() action,
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
      await action();
      if (!_valid(epoch, scope)) return;
      setState(() {
        if (_notice.isEmpty) _notice = notice;
      });
      if (reload) await _load();
    } catch (e) {
      if (_valid(epoch, scope)) setState(() => _error = '$e');
    } finally {
      if (mounted && scope == _accountScope) setState(() => _saving = false);
    }
  }

  Future<void> _delete(String kind, Map<String, dynamic> row) async {
    if (!await _confirm(
      '删除${_panels[kind] ?? '内容'}',
      '确定删除「${textOf(row, 'title', textOf(row, 'username', textOf(row, 'name', textOf(row, 'id'))))}」？此操作无法撤销。',
    )) {
      return;
    }
    await _mutate(() async {
      if (kind == 'gallery' || kind == 'attachments') {
        await (c.site as SiteDataService).request(
          c.settings.siteUrl,
          'POST',
          '/api/assets/${row['id']}/delete',
        );
      } else {
        await api.data(
          'DELETE',
          '/$kind/${Uri.encodeComponent('${row['id']}')}',
        );
      }
    }, '已删除');
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    final hosts = mapOf(row['moderation'])['externalHosts'];
    final external = hosts is List && hosts.isNotEmpty;
    if (external &&
        !await _confirm('核对外部链接', '该留言包含：${hosts.join('、')}。确认已核对域名并通过审核？')) {
      return;
    }
    await _mutate(() async {
      await api.data(
        'POST',
        '/messages/${row['id']}/approve',
        ManagementService.approval(row, confirmedExternalLinks: external),
      );
    }, '留言已通过');
  }

  Future<void> _editUser(Map<String, dynamic> row, String action) async {
    final label = action == 'password' ? '新密码' : '昵称';
    final result = await _form(action == 'password' ? '重置用户密码' : '修改用户昵称', {
      label: action == 'password' ? '' : userDisplayName(row),
    }, secrets: action == 'password' ? {label} : {});
    if (result == null) return;
    final value = result[label] ?? '';
    await _mutate(() async {
      if (action == 'password' && value.length < 8) {
        throw const ApiFailure('新密码至少 8 位');
      }
      if (action == 'nickname' && nicknameError(value) != null) {
        throw ApiFailure(nicknameError(value)!);
      }
      await api.data(
        'POST',
        '/users/${Uri.encodeComponent('${row['id']}')}/$action',
        {action: action == 'nickname' ? value.trim() : value},
      );
    }, '用户资料已更新');
  }

  Future<void> _createLink() async {
    final values = await _form('收录友链', {
      '名称': '',
      '网站地址': '',
      '描述': '',
      '头像地址': '',
      '回链地址': '',
    });
    if (values == null) return;
    await _mutate(() async {
      await api.data('POST', '/links', {
        'name': values['名称'],
        'url': values['网站地址'],
        'description': values['描述'],
        'avatar_url': values['头像地址'],
        'backlink_url': values['回链地址'],
      });
    }, '友链已创建');
  }

  Future<void> _category({Map<String, dynamic>? remove}) async {
    if (remove != null) {
      if (!await _confirm('删除分类', '分类「${remove['name']}」中的文章会移至默认分类。')) return;
      await _mutate(() async {
        await api.request('DELETE', '/article-categories/${remove['id']}');
      }, '分类已删除');
    } else {
      final result = await _form('添加分类', {'分类名称': ''});
      if (result == null) return;
      await _mutate(() async {
        await api.request('POST', '/article-categories', {
          'name': result['分类名称'],
        });
      }, '分类已添加');
    }
  }

  Map<String, dynamic> _settingsBody() => {
    for (final key in {..._siteFields, if (superAdmin) ..._ossFields}.keys)
      key: _booleanFields.contains(key)
          ? _values[key] == true
          : _field(key).text,
  };
  Future<void> _ossImport(bool scan) async {
    final values = await _form(
      scan ? '扫描并登记对象存储文件' : '登记对象存储文件',
      scan
          ? {
              '对象前缀': '',
              '最多扫描数量': '100',
              '类型（auto/image/video/audio/file）': 'auto',
              '可见性（public/private）': 'public',
            }
          : {
              'Object Key': '',
              '标题': '',
              '描述': '',
              '类型（auto/image/video/audio/file）': 'auto',
              'MIME 类型': '',
              '大小（字节）': '',
              '可见性（public/private）': 'public',
            },
    );
    if (values == null) return;
    await _mutate(
      () async {
        final body = <String, dynamic>{
          'assetType': values['类型（auto/image/video/audio/file）'],
          'visibility': values['可见性（public/private）'],
          if (scan) ...{
            'prefix': values['对象前缀'],
            'maxKeys': int.tryParse(values['最多扫描数量'] ?? '') ?? 100,
          } else ...{
            'objectKey': values['Object Key'],
            'title': values['标题'],
            'description': values['描述'],
            'mimeType': values['MIME 类型'],
            'size': values['大小（字节）'],
          },
        };
        final result = await (c.site as SiteDataService).request(
          c.settings.siteUrl,
          'POST',
          '/api/assets/oss-${scan ? 'scan' : 'register'}',
          body,
        );
        if (scan) {
          final data = mapOf(result['data']);
          if (mounted) {
            setState(
              () => _notice =
                  '扫描 ${data['scannedCount'] ?? 0} 个，登记 ${data['importedCount'] ?? 0} 个，跳过 ${data['skippedCount'] ?? 0} 个',
            );
          }
        }
      },
      scan ? '扫描完成' : '文件已登记',
      reload: false,
    );
  }

  Widget _button(String title, VoidCallback onPressed, {bool enabled = true}) =>
      TextButton(
        onPressed: enabled && !_saving && !_loading ? onPressed : null,
        child: Text(title),
      );
  Widget _metrics(Map<String, dynamic> values) {
    const labels = {
      'articles': '文章',
      'messages': '留言',
      'gallery': '画廊',
      'attachments': '附件',
      'pendingMessages': '待审核留言',
      'users': '用户',
      'todayViews': '今日访问',
      'weekViews': '近七日访问',
      'monthViews': '近三十日访问',
      'totalViews': '总访问',
      'articleViews': '文章阅读',
    };
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final key in labels.keys)
            if (values.containsKey(key))
              SizedBox(
                width: constraints.maxWidth < 600
                    ? (constraints.maxWidth - 16) / 2
                    : 210,
                child: SiteCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(labels[key]!),
                      const SizedBox(height: 10),
                      Text(
                        values[key] is Map
                            ? '${mapOf(values[key])['all'] ?? 0}'
                            : '${values[key]}',
                        style: const TextStyle(fontSize: 32),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final id = '${row['id']}';
    final title = _panel == 'messages'
        ? userDisplayName(row, fallback: userDisplayName(row, prefix: 'author'))
        : textOf(
            row,
            'title',
            userDisplayName(row, fallback: textOf(row, 'name', '附件 $id')),
          );
    final actions = <Widget>[];
    if (_panel == 'articles') {
      actions.addAll([
        _button('编辑', () => widget.onGo('/editor?id=$id')),
        _button(
          row['status'] == 'published' ? '下架' : '发布',
          () => _mutate(() async {
            await api.data('POST', '/articles/$id/toggle-status');
          }, '文章状态已更新'),
        ),
        _button(
          row['pinned_at'] != null ? '取消置顶' : '置顶',
          () => _mutate(() async {
            await api.data('POST', '/articles/$id/toggle-pin');
          }, '置顶状态已更新'),
        ),
        _button('查看', () => widget.onGo('/articles/$id')),
      ]);
    }
    if (_panel == 'messages') {
      actions.add(
        _button(
          '通过审核',
          () => _approve(row),
          enabled:
              row['status'] != 'approved' &&
              mapOf(row['moderation'])['blocked'] != true,
        ),
      );
    }
    if (_panel == 'users') {
      actions.addAll([
        _button('修改昵称', () => _editUser(row, 'nickname'), enabled: superAdmin),
        _button('重置密码', () => _editUser(row, 'password'), enabled: superAdmin),
        for (final role in const {
          'user': '设为用户',
          'admin': '设为管理员',
          'banned': '封禁',
        }.entries)
          _button(
            role.value,
            () async {
              if (!await _confirm(
                '修改用户角色',
                '将「$title」设置为${role.value.replaceFirst('设为', '')}？',
              )) {
                return;
              }
              await _mutate(() async {
                await api.data(
                  'PATCH',
                  '/users/${Uri.encodeComponent(id)}/role',
                  {'role': role.key},
                );
              }, '角色已更新');
            },
            enabled:
                superAdmin &&
                row['username'] != 'admin' &&
                row['role'] != role.key,
          ),
      ]);
    }
    if (_panel == 'links') {
      actions.addAll([
        for (final entry in const {
          'active': '通过',
          'pending': '待审',
          'rejected': '拒绝',
        }.entries)
          _button(
            entry.value,
            () => _mutate(() async {
              await api.data('POST', '/links/$id/status', {
                'status': entry.key,
              });
            }, '友链状态已更新'),
          ),
        _button(
          '刷新头像',
          () => _mutate(() async {
            await api.data('POST', '/links/$id/avatar', {});
          }, '头像已刷新'),
        ),
        _button(
          '检查回链',
          () => _mutate(() async {
            await api.data('POST', '/links/$id/check', {});
          }, '回链检查完成'),
        ),
      ]);
    }
    if (_panel == 'gallery' || _panel == 'attachments') {
      actions.add(
        _button(
          '打开文件',
          () => openSiteLink(
            c.settings.siteUrl,
            textOf(row, 'url', textOf(row, 'public_url')),
          ),
        ),
      );
    }
    actions.add(
      _button(
        '删除',
        () => _delete(_panel, row),
        enabled:
            _panel != 'users' ||
            (superAdmin &&
                row['role'] != 'admin' &&
                row['username'] != 'admin'),
      ),
    );
    final moderation = mapOf(row['moderation']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SiteCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              [
                '#$id',
                textOf(row, 'status'),
                textOf(row, 'role'),
                textOf(row, 'email'),
                dateText(row['created_at']),
              ].where((v) => v.isNotEmpty).join(' · '),
            ),
            if (_panel == 'messages') ...[
              const SizedBox(height: 10),
              SelectableText(textOf(row, 'content')),
              if (row['article_title'] != null)
                Text('文章：${row['article_title']}'),
              if (moderation['blocked'] == true)
                const SiteText('包含禁止发布的内容，不能通过审核'),
              if (moderation['externalHosts'] is List &&
                  (moderation['externalHosts'] as List).isNotEmpty)
                Text('外部链接：${(moderation['externalHosts'] as List).join('、')}'),
              if (moderation['matchedKeywords'] is List &&
                  (moderation['matchedKeywords'] as List).isNotEmpty)
                Text(
                  '审核关键词：${(moderation['matchedKeywords'] as List).join('、')}',
                ),
            ],
            if (_panel == 'links') ...[
              SelectableText(textOf(row, 'url')),
              Text(textOf(row, 'description')),
              Text('回链：${textOf(row, 'backlink_url')}'),
              if (row['backlink_status'] != null)
                Text('检查结果：${row['backlink_status']}'),
            ],
            const SizedBox(height: 8),
            Wrap(children: actions),
          ],
        ),
      ),
    );
  }

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final group in [_siteFields, if (superAdmin) _ossFields])
        NativeSiteSection(
          title: identical(group, _siteFields) ? '站点与备案' : '对象存储',
          child: Column(
            children: [
              for (final entry in group.entries)
                if (_booleanFields.contains(entry.key))
                  SwitchListTile(
                    title: Text(entry.value),
                    value: _values[entry.key] == true,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _values[entry.key] = value),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _field(entry.key),
                      enabled: !_saving,
                      obscureText: entry.key == 'ossAccessKeySecret',
                      maxLines:
                          [
                            'siteAnnouncement',
                            'visitPopupContent',
                            'messageReviewKeywords',
                          ].contains(entry.key)
                          ? 4
                          : 1,
                      decoration: InputDecoration(
                        labelText: entry.value,
                        hintText: entry.key == 'ossAccessKeySecret'
                            ? '留空保留已保存的密钥'
                            : null,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      FilledButton(
        onPressed: _saving || _loading
            ? null
            : () => _mutate(() async {
                await api.data('POST', '/settings', _settingsBody());
              }, '配置已保存'),
        child: const SiteText('保存站点配置'),
      ),
      if (superAdmin) ...[
        const SizedBox(height: 12),
        Wrap(
          children: [
            _button(
              '测试对象存储配置',
              () => _mutate(
                () async {
                  final data = mapOf(
                    await api.data(
                      'POST',
                      '/settings/oss-test',
                      _settingsBody(),
                    ),
                  );
                  final checks = rowsOf(data['checks']);
                  if (mounted) {
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(
                          data['usable'] == true ? '对象存储测试通过' : '对象存储检查结果',
                        ),
                        content: SingleChildScrollView(
                          child: Text(
                            checks
                                .map(
                                  (r) =>
                                      '${r['name']}：${r['status']} ${r['message'] ?? ''}',
                                )
                                .join('\n'),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const SiteText('关闭'),
                          ),
                        ],
                      ),
                    );
                  }
                },
                '检测已完成',
                reload: false,
              ),
            ),
            _button('登记存储文件', () => _ossImport(false)),
            _button('扫描存储文件', () => _ossImport(true)),
          ],
        ),
      ],
    ],
  );
  Widget _notifications() => NativeSiteSection(
    title: '审核邮件与通知',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('接收邮箱：${textOf(_preference, 'email', '未绑定')}'),
        Text(_preference['mailConfigured'] == true ? '邮件服务已配置' : '站点尚未配置邮件服务'),
        SwitchListTile(
          title: const SiteText('待审核留言邮件提醒'),
          value: _preference['emailNotifyModeration'] == true,
          onChanged: _saving || _preference['canReceive'] != true
              ? null
              : (value) => setState(
                  () => _preference['emailNotifyModeration'] = value,
                ),
        ),
        if (superAdmin)
          for (final entry in const {
            'emailNotifyReplies': '回复邮件',
            'emailNotifyLikes': '点赞邮件',
            'emailNotifyUnusualLogin': '异常登录邮件',
          }.entries)
            SwitchListTile(
              title: Text(entry.value),
              value: _values[entry.key] == true,
              onChanged: _saving
                  ? null
                  : (v) => setState(() => _values[entry.key] = v),
            ),
        FilledButton(
          onPressed: _saving || _loading
              ? null
              : () => _mutate(() async {
                  await api.data('POST', '/notification-preferences', {
                    'emailNotifyModeration':
                        _preference['emailNotifyModeration'] == true,
                  });
                  if (superAdmin) {
                    await api.data('POST', '/settings', {
                      for (final key in [
                        'emailNotifyReplies',
                        'emailNotifyLikes',
                        'emailNotifyUnusualLogin',
                      ])
                        key: _values[key] == true,
                    });
                  }
                }, '通知设置已保存'),
          child: const SiteText('保存通知设置'),
        ),
      ],
    ),
  );
  Widget _account() => NativeSiteSection(
    title: '管理员账号安全',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('当前账号：${userDisplayName(_admin)}'),
        for (final label in ['当前密码', '新密码', '确认新密码'])
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(
              controller: _field(label),
              obscureText: true,
              decoration: InputDecoration(labelText: label),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving
              ? null
              : () => _mutate(
                  () async {
                    final password = _field('新密码').text;
                    if (password.length < 8) {
                      throw const ApiFailure('新密码至少 8 位');
                    }
                    if (password != _field('确认新密码').text) {
                      throw const ApiFailure('两次新密码不一致');
                    }
                    await api.data('POST', '/password', {
                      'currentPassword': _field('当前密码').text,
                      'newPassword': password,
                    });
                    for (final label in ['当前密码', '新密码', '确认新密码']) {
                      _field(label).clear();
                    }
                  },
                  '管理员密码已更新',
                  reload: false,
                ),
          child: const SiteText('更新密码'),
        ),
      ],
    ),
  );
  Widget _content() {
    if (_panel == 'dashboard' || _panel == 'analytics') {
      return _metrics(_values);
    }
    if (_panel == 'settings') return _settings();
    if (_panel == 'notifications') return _notifications();
    if (_panel == 'account') return _account();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!terminal) ...[_metrics(_summary), const SizedBox(height: 16)],
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _search,
                onSubmitted: (_) {
                  _page = 1;
                  _load();
                },
                decoration: const InputDecoration(
                  labelText: '搜索',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            _button('搜索', () {
              _page = 1;
              _load();
            }),
            if (_panel == 'links') _button('收录友链', _createLink),
          ],
        ),
        const SizedBox(height: 12),
        if (['articles', 'messages', 'links'].contains(_panel))
          Wrap(
            spacing: 8,
            children: [
              for (final status
                  in (_panel == 'articles'
                      ? ['all', 'published', 'draft']
                      : _panel == 'messages'
                      ? ['all', 'pending', 'approved']
                      : ['all', 'pending', 'active', 'rejected']))
                ChoiceChip(
                  label: Text(
                    const {
                      'all': '全部',
                      'published': '已发布',
                      'draft': '草稿',
                      'pending': '待审核',
                      'approved': '已通过',
                      'active': '已收录',
                      'rejected': '已拒绝',
                    }[status]!,
                  ),
                  selected: _status == status,
                  onSelected: _loading
                      ? null
                      : (_) {
                          setState(() {
                            _status = status;
                            _page = 1;
                          });
                          _load();
                        },
                ),
            ],
          ),
        if (_panel == 'articles') ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              for (final row in _categories)
                InputChip(
                  label: Text(textOf(row, 'name')),
                  onDeleted:
                      row['protected'] == true ||
                          row['protected'] == 1 ||
                          _saving
                      ? null
                      : () => _category(remove: row),
                ),
              _button('添加分类', () => _category()),
            ],
          ),
        ],
        const SizedBox(height: 16),
        for (final row in _rows) _row(row),
        if (_rows.isEmpty && !_loading)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: SiteText('暂无内容')),
          ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _button('上一页', () {
              _page--;
              _load();
            }, enabled: _page > 1),
            Text('$_page / $_totalPages · 共 $_total 条'),
            _button('下一页', () {
              _page++;
              _load();
            }, enabled: _page < _totalPages),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: terminal ? '管理终端' : '内容管理',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _admin.isEmpty ? _verify : _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error.isNotEmpty)
          nativeSiteFeedback(
            context,
            _error,
            error: true,
            retry: _admin.isEmpty ? _verify : _load,
          ),
        if (_notice.isNotEmpty) nativeSiteFeedback(context, _notice),
        if (_loading) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        if (_admin.isEmpty && !_loading)
          NativeSiteSection(
            title: '需要管理员权限',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SiteText('请使用 admin 或 super_admin 角色账号登录。'),
                if (terminal &&
                    c.account?.isAdministrator == true &&
                    !c.sessionExpired) ...[
                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(labelText: '管理员账号'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    onSubmitted: (_) {
                      if (!_saving) _login();
                    },
                    decoration: const InputDecoration(labelText: '密码'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _saving ? null : _login,
                    child: Text(_saving ? '登录中…' : '登录管理终端'),
                  ),
                ],
                TextButton(
                  onPressed: () async {
                    await showSiteLogin(context, c);
                    if (mounted) await _verify();
                  },
                  child: const SiteText('使用站点管理员账号登录'),
                ),
              ],
            ),
          ),
        if (_admin.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final panel in panels)
                ChoiceChip(
                  label: Text(_panels[panel]!),
                  selected: _panel == panel,
                  onSelected: _saving
                      ? null
                      : (_) {
                          setState(() {
                            _panel = panel;
                            _page = 1;
                            _status = 'all';
                            _search.clear();
                            _rows = [];
                            _values = {};
                            _notice = '';
                          });
                          _load();
                        },
                ),
              if (terminal && !_terminalSession)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () {
                          setState(() {
                            _admin = {};
                            _rows = [];
                            _values = {};
                          });
                        },
                  child: const SiteText('验证终端账号'),
                ),
              if (terminal)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          try {
                            if (_terminalSession) {
                              await (c.site as SiteDataService).request(
                                c.settings.siteUrl,
                                'POST',
                                '/api/admin/logout',
                              );
                            } else {
                              await c.logout();
                            }
                            if (mounted) {
                              setState(() {
                                _admin = {};
                                _values = {};
                                _rows = [];
                              });
                            }
                          } catch (e) {
                            if (mounted) setState(() => _error = '$e');
                          }
                        },
                  child: const SiteText('退出终端'),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _content(),
        ],
      ],
    ),
  );
}
