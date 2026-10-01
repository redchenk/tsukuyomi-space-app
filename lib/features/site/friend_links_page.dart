import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/site_client.dart';
import '../../core/site_repository.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import 'friend_link_application.dart';
import 'login_dialog.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class FriendLinksPage extends StatefulWidget {
  const FriendLinksPage({
    super.key,
    required this.controller,
    this.path = '/friend-links',
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<FriendLinksPage> createState() => _FriendLinksPageState();
}

class _FriendLinksPageState extends State<FriendLinksPage> {
  late final SiteRepository _repo;
  final _form = GlobalKey<FormState>();
  final _fields = {
    for (final key in FriendLinkApplication.limits.keys)
      key: TextEditingController(),
  };
  List<Map<String, dynamic>> _links = [], _mine = [];
  String _error = '', _notice = '', _success = '', _scope = '';
  bool _loading = true, _submitting = false, _discovering = false;
  int _generation = 0, _draftTicket = 0;
  Future<void> _draftWrites = Future<void>.value();
  RoomController get c => widget.controller;
  bool get apply => Uri.parse(widget.path).path.endsWith('/apply');
  bool get authed => c.account != null && !c.sessionExpired;
  String get draftKey => 'friend-link-application:${_repo.scope}';
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
    _restore();
    _load();
  }

  @override
  void didUpdateWidget(covariant FriendLinksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _success = '';
      _load();
    }
  }

  void _accountChanged() {
    if (_scope != _repo.scope) {
      _scope = _repo.scope;
      _generation++;
      _mine = [];
      _success = '';
      _error = '';
      _submitting = false;
      _discovering = false;
      for (final field in _fields.values) {
        field.clear();
      }
      _restore();
      _load();
    }
    if (mounted) setState(() {});
  }

  Future<void> _restore() async {
    final owner = _repo.scope, ticket = ++_draftTicket;
    try {
      final raw = await c.storage.draft(draftKey);
      if (!mounted ||
          owner != _repo.scope ||
          ticket != _draftTicket ||
          raw.isEmpty) {
        return;
      }
      final fields = mapOf(jsonDecode(raw));
      for (final key in _fields.keys) {
        _fields[key]!.text = textOf(fields, key);
      }
    } catch (_) {
      /* Missing drafts do not affect the live application form. */
    }
  }

  void _saveDraft() {
    _draftTicket++;
    final key = draftKey;
    final value = jsonEncode({
      for (final entry in _fields.entries) entry.key: entry.value.text,
    });
    _draftWrites = _draftWrites
        .then((_) => c.storage.saveDraft(key, value))
        .catchError((_) {});
    unawaited(_draftWrites);
  }

  Future<void> _load() async {
    final ticket = ++_generation;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      if (apply && !authed) {
        _mine = [];
        return;
      }
      final result = await _repo.read(
        apply ? '/api/friend-links/mine' : '/api/friend-links',
        private: apply,
      );
      if (!mounted || ticket != _generation) return;
      setState(() {
        if (apply) {
          _mine = rowsOf(result.data);
        } else {
          _links = rowsOf(result.data);
        }
        _notice = result.notice;
      });
    } catch (e) {
      if (mounted && ticket == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted && ticket == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _discover() async {
    if (_discovering || _submitting) return;
    if (!authed) {
      await showSiteLogin(context, c);
      return;
    }
    final error = FriendLinkApplication.validate('url', _fields['url']!.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final owner = _repo.scope, url = _fields['url']!.text.trim();
    setState(() {
      _discovering = true;
      _error = '';
    });
    try {
      final result = await _repo.write(
        'POST',
        '/api/friend-links/discover-avatar',
        {'url': url},
      );
      if (!mounted ||
          owner != _repo.scope ||
          url != _fields['url']!.text.trim()) {
        return;
      }
      final avatar = textOf(mapOf(result['data']), 'avatar_url');
      if (avatar.isEmpty) throw StateError('未能自动获取站点头像');
      setState(() => _fields['avatar_url']!.text = avatar);
      _saveDraft();
    } catch (e) {
      if (mounted && owner == _repo.scope) setState(() => _error = '$e');
    } finally {
      if (mounted && owner == _repo.scope) setState(() => _discovering = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting || _discovering) return;
    if (!authed) {
      await showSiteLogin(context, c);
      return;
    }
    if (!_form.currentState!.validate()) return;
    final owner = _repo.scope;
    setState(() {
      _submitting = true;
      _error = '';
      _success = '';
    });
    try {
      final result = await _repo.write(
        'POST',
        '/api/friend-links',
        FriendLinkApplication.body({
          for (final entry in _fields.entries) entry.key: entry.value.text,
        }),
      );
      if (!mounted || owner != _repo.scope) return;
      setState(() => _success = textOf(result, 'message', '申请已提交，审核结果可在本页查看'));
      await _load();
    } catch (e) {
      if (mounted && owner == _repo.scope) setState(() => _error = '$e');
    } finally {
      if (mounted && owner == _repo.scope) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    _draftTicket++;
    c.removeListener(_accountChanged);
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: apply ? '友链申请' : '友链',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SitePageHero(
          title: apply ? '友链申请' : '友链',
          subtitle: apply ? '填写站点信息，审核通过后将在月读广场展示。' : '一些值得顺路拜访的站点。',
          actions: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: () =>
                    widget.onGo(apply ? '/friend-links' : '/plaza'),
                icon: const Icon(Icons.arrow_back),
                label: SiteText(apply ? '返回友链' : '返回广场'),
              ),
              if (!apply)
                FilledButton(
                  onPressed: () => widget.onGo('/friend-links/apply'),
                  child: const SiteText('申请友链'),
                ),
            ],
          ),
        ),
        if (_error.isNotEmpty)
          nativeSiteFeedback(context, _error, error: true, retry: _load),
        if (_notice.isNotEmpty)
          nativeSiteFeedback(context, _notice, retry: _load),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (apply) ..._application() else ..._directory(),
      ],
    ),
  );
  List<Widget> _directory() => [
    if (!_loading && _links.isEmpty && _error.isEmpty)
      NativeSiteSection(
        title: '暂时还没有公开友链',
        child: FilledButton(
          onPressed: () => widget.onGo('/friend-links/apply'),
          child: const SiteText('成为第一个友邻'),
        ),
      ),
    LayoutBuilder(
      builder: (context, box) {
        final columns = (box.maxWidth / 360).floor().clamp(1, 3),
            width = (box.maxWidth - 16 * (columns - 1)) / columns;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final link in _links)
              SizedBox(
                width: width,
                child: SiteCard(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        InkWell(
                          onTap: () => widget.onGo(textOf(link, 'url')),
                          child: nativeSiteImage(
                            c.settings.siteUrl,
                            textOf(link, 'screenshot_url'),
                            height: 170,
                            width: width,
                            label: '${link['name']} preview',
                            fallback: SizedBox(
                              height: 170,
                              child: Center(
                                child: SiteAvatar(
                                  value: textOf(link, 'avatar_url'),
                                  name: textOf(link, 'name'),
                                  site: c.settings.siteUrl,
                                  size: 70,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                textOf(link, 'name'),
                                style: const TextStyle(fontSize: 23),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                textOf(link, 'description'),
                                style: const TextStyle(height: 1.7),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _monitor(link),
                                style: TextStyle(
                                  color: RoomStyle(context).accent,
                                ),
                              ),
                              Text(
                                '${link['has_backlink'] == true || link['has_backlink'] == 1 ? '已发现回链' : '未发现回链'} · 检测于 ${dateText(link['last_checked_at'])}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: () =>
                                    widget.onGo(textOf(link, 'url')),
                                icon: const Icon(Icons.open_in_new, size: 16),
                                label: Text(
                                  Uri.tryParse(textOf(link, 'url'))?.host ??
                                      '访问站点',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  ];
  String _monitor(Map link) {
    const labels = {
      'online': '在线',
      'slow': '响应较慢',
      'restricted': '访问受限',
      'offline': '暂时离线',
    };
    final status = textOf(link, 'monitor_status'),
        latency = link['response_time_ms'];
    return '${labels[status] ?? '等待检测'}${latency is num && latency > 0 && status != 'offline' ? ' · ${latency}ms' : ''}';
  }

  List<Widget> _application() => [
    if (_success.isNotEmpty)
      NativeSiteSection(
        title: '申请已提交',
        subtitle: _success,
        child: Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: () => widget.onGo('/friend-links'),
              child: const SiteText('返回友链'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _success = ''),
              child: const SiteText('继续编辑申请'),
            ),
          ],
        ),
      )
    else if (!authed)
      NativeSiteSection(
        title: '登录后申请',
        subtitle: '申请记录将绑定当前账号，方便查看审核状态。',
        child: FilledButton(
          onPressed: () => showSiteLogin(context, c),
          child: const SiteText('去登录'),
        ),
      )
    else
      NativeSiteSection(
        title: '站点信息',
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in const {
                'name': '站点名称',
                'url': '站点地址',
                'description': '站点简介',
                'avatar_url': '头像链接',
                'backlink_url': '友链页地址（建议填写）',
                'note': '备注（选填）',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextFormField(
                    key: Key('friend-${entry.key}'),
                    controller: _fields[entry.key],
                    enabled: !_submitting,
                    onChanged: (_) {
                      _saveDraft();
                      if (entry.key == 'avatar_url') setState(() {});
                    },
                    maxLength: FriendLinkApplication.limits[entry.key],
                    maxLines: ['description', 'note'].contains(entry.key)
                        ? 3
                        : 1,
                    validator: (v) =>
                        FriendLinkApplication.validate(entry.key, v ?? ''),
                    decoration: InputDecoration(
                      labelText: siteTranslate(context, entry.value),
                      hintText:
                          [
                            'url',
                            'avatar_url',
                            'backlink_url',
                          ].contains(entry.key)
                          ? 'https://example.com'
                          : null,
                      helperText: entry.key == 'backlink_url'
                          ? siteTranslate(context, '系统会定期检查页面中是否存在指向本站的真实链接。')
                          : null,
                    ),
                  ),
                ),
              if (_fields['avatar_url']!.text.isNotEmpty)
                SiteAvatar(
                  value: _fields['avatar_url']!.text.trim(),
                  name: _fields['name']!.text,
                  site: c.settings.siteUrl,
                  size: 72,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _discovering || _submitting ? null : _discover,
                  icon: const Icon(Icons.image_search),
                  label: SiteText(_discovering ? '获取中' : '自动获取头像'),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('friend-submit'),
                onPressed: _submitting || _discovering ? null : _submit,
                child: SiteText(_submitting ? '提交中' : '提交申请'),
              ),
            ],
          ),
        ),
      ),
    const NativeSiteSection(
      title: '收录条件',
      child: SiteText(
        '• 站点可正常访问\n• 内容合法且无恶意跳转\n• 建议添加本站友链',
        style: TextStyle(height: 2),
      ),
    ),
    if (authed)
      NativeSiteSection(
        title: '我的申请',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_mine.isEmpty && !_loading) const SiteText('还没有申请记录'),
            for (final item in _mine)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SiteAvatar(
                  value: textOf(item, 'avatar_url'),
                  name: textOf(item, 'name'),
                  site: c.settings.siteUrl,
                ),
                title: Text(textOf(item, 'name')),
                subtitle: Text(
                  '${item['url']}\n${dateText(item['updated_at'] ?? item['created_at'])}${textOf(item, 'review_note').isEmpty ? '' : '\n审核说明：${item['review_note']}'}',
                ),
                isThreeLine: true,
                trailing: SiteText(
                  const {
                        'pending': '审核中',
                        'active': '已收录',
                        'rejected': '未通过',
                      }[item['status']] ??
                      textOf(item, 'status'),
                ),
              ),
          ],
        ),
      ),
  ];
}
