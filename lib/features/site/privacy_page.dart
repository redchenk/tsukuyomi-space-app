import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/privacy_policy.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class PrivacyPage extends StatefulWidget {
  const PrivacyPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.path = '/privacy',
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final String path;
  final VoidCallback? onTheme;
  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<PrivacyPage> {
  RoomController get c => widget.controller;
  final Map<String, dynamic> _policy = privacyPolicy;
  // The 24 October policy adds QQ SDK disclosure only. Its deletion terms
  // are identical to 23 October, which the deployed website still accepts.
  // A future policy version must be assessed again instead of reusing this.
  String get _deletionPolicyVersion => _policy['version'] == '2026-10-24'
      ? '2026-10-23'
      : textOf(_policy, 'version');
  Map<String, dynamic> _request = {};
  String _error = '', _scope = '';
  bool _busy = false, _loading = true, _confirmed = false;
  int _epoch = 0;
  bool get _deleting => Uri.parse(widget.path).path == '/delete-account';
  bool get _loggedIn => !c.loading && c.account != null && !c.sessionExpired;
  String get _identity =>
      '${endpointUri(c.settings.siteUrl).origin}:${c.account?.id}:${c.sessionExpired}:${c.loading}:${c.site is SiteClient ? (c.site as SiteClient).sessionRevision : 0}';
  bool get _english =>
      (SiteLocaleScope.maybeOf(context)?.language ?? 'zh') != 'zh';
  String t(String zh, String en) => _english ? en : zh;

  @override
  void initState() {
    super.initState();
    _scope = _identity;
    c.addListener(_accountChanged);
    if (_deleting) _load();
  }

  void _accountChanged() {
    if (_scope == _identity) return;
    _scope = _identity;
    _epoch++;
    setState(() {
      _request = {};
      _confirmed = false;
      _error = '';
      _busy = false;
    });
    if (_deleting) _load();
  }

  @override
  void didUpdateWidget(covariant PrivacyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_accountChanged);
      c.addListener(_accountChanged);
      _accountChanged();
    }
    if (oldWidget.path != widget.path) {
      _epoch++;
      _request = {};
      _confirmed = false;
      if (_deleting) _load();
    }
  }

  @override
  void dispose() {
    _epoch++;
    c.removeListener(_accountChanged);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_loggedIn) {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
      return;
    }
    await _run(
      'GET',
      '/api/account-deletion/me?_=${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  Future<void> _run(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (!_loggedIn) return;
    final epoch = ++_epoch, scope = _identity;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final result = await (c.site as SiteDataService).request(
        c.settings.siteUrl,
        method,
        path,
        body,
      );
      if (!mounted || epoch != _epoch || scope != _identity || !_loggedIn) {
        return;
      }
      setState(() {
        _request = mapOf(result['data']);
        _confirmed = false;
      });
    } catch (error) {
      if (mounted && epoch == _epoch && scope == _identity) {
        setState(() {
          _error = error is ApiFailure
              ? error.message
              : t(
                  '请求失败，请重试或通过邮箱联系。',
                  'Request failed. Retry or contact us by email.',
                );
        });
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() {
          _busy = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _email() async {
    final uri = Uri(
      scheme: 'mailto',
      path: 'redchenk919@gmail.com',
      queryParameters: {'subject': '月读空间 / Tsukuyomi Space 账号注销申请'},
    );
    try {
      if (await launchUrl(uri)) return;
    } catch (_) {
      /* Address remains selectable. */
    }
    if (mounted) {
      setState(() {
        _error = t(
          '未能打开邮件应用，请复制邮箱地址自行发送。',
          'Could not open mail. Copy the email address and send your request.',
        );
      });
    }
  }

  Widget _paragraph(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: SelectableText(text, style: const TextStyle(height: 1.8)),
  );
  Widget _requestCard() {
    final status = textOf(_request, 'status');
    final active = ['pending', 'processing'].contains(status);
    final label = {
      'pending': t('等待站长核验', 'Awaiting verification'),
      'processing': t('站长处理中', 'Being processed'),
      'cancelled': t('已撤回申请', 'Request cancelled'),
      'completed': t('已完成处理', 'Completed'),
    }[status];
    return SiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t('提交与进度', 'Request and status'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          _paragraph(
            t(
              '由站长核验身份并处理，通常在收到申请后 30 日内完成。提交申请不会立即删除账号或扣除余额。',
              'The administrator verifies and handles your request, normally within 30 days of receipt. Submitting does not immediately delete your account or deduct your balance.',
            ),
          ),
          if (_busy || _loading) const LinearProgressIndicator(),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error,
                key: const Key('deletion-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_request.isNotEmpty) ...[
            Text(
              label ?? status,
              key: const Key('deletion-status'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            _paragraph('${t('申请编号', 'Reference')}: ${textOf(_request, 'id')}'),
            _paragraph(
              '${t('预计处理日期', 'Expected handling date')}: ${textOf(_request, 'due_at').split('T').first}',
            ),
            if (textOf(_request, 'resolution').isNotEmpty)
              _paragraph(textOf(_request, 'resolution')),
            _paragraph(
              t(
                '请保存申请编号。完成后会通过核验后的邮箱通知。',
                'Keep your reference number. Completion will be sent to your verified email.',
              ),
            ),
          ],
          if (_loggedIn && !_loading && !active && _error.isEmpty) ...[
            CheckboxListTile(
              key: const Key('deletion-confirm'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                      _confirmed = v ?? false;
                    }),
              title: Text(
                t(
                  '我已阅读下方说明，申请注销当前账号及关联数据。',
                  'I have read the information below and request deletion of my account and associated data.',
                ),
              ),
            ),
            FilledButton(
              key: const Key('deletion-submit'),
              onPressed: !_confirmed || _busy || _policy.isEmpty
                  ? null
                  : () => _run('POST', '/api/account-deletion', {
                      'confirmation': 'DELETE_ACCOUNT',
                      'policyVersion': _deletionPolicyVersion,
                    }),
              child: Text(t('提交注销申请', 'Submit deletion request')),
            ),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (_loggedIn)
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: Text(t('刷新状态', 'Refresh status')),
                ),
              if (_loggedIn && status == 'pending')
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          'POST',
                          '/api/account-deletion/${Uri.encodeComponent(textOf(_request, 'id'))}/cancel',
                          {},
                        ),
                  child: Text(t('撤回申请', 'Cancel request')),
                ),
              if (!_loggedIn)
                FilledButton(
                  onPressed: () =>
                      widget.onGo('/login?redirect=/delete-account'),
                  child: Text(t('登录后在线提交', 'Sign in to submit')),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            t('无法登录或已卸载 App？', 'Cannot sign in or already uninstalled?'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          _paragraph(
            t(
              '无需重新安装。请从绑定邮箱发送用户名和注销或部分数据删除请求，不要发送密码、验证码或 API 密钥。',
              'No reinstall is needed. Email us from your linked address with your username and account or selected-data deletion request. Never send passwords, verification codes or API keys.',
            ),
          ),
          const SelectableText('redchenk919@gmail.com'),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _email,
              icon: const Icon(Icons.mail_outline),
              label: Text(t('发送注销申请邮件', 'Email a deletion request')),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = mapOf(_policy[_english ? 'en' : 'zh']);
    final allSections = rowsOf(copy['sections']);
    final sections = _deleting ? allSections.skip(7).take(3) : allSections;
    return NativeSiteShell(
      controller: c,
      title: _deleting
          ? t('申请注销账号', 'Request account deletion')
          : t('隐私政策', 'Privacy policy'),
      onGo: widget.onGo,
      onTheme: widget.onTheme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SitePageHero(
            title: _deleting
                ? t('申请注销账号', 'Request account deletion')
                : t('隐私政策', 'Privacy policy'),
            subtitle: '月读空间 · Tsukuyomi Space\n${textOf(_policy, 'updatedAt')}',
            actions: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      widget.onGo(_deleting ? '/privacy' : '/delete-account'),
                  child: Text(
                    _deleting
                        ? t('完整隐私政策', 'Full privacy policy')
                        : t('申请注销账号', 'Request account deletion'),
                  ),
                ),
              ],
            ),
          ),
          if (_deleting) _requestCard(),
          if (!_deleting && _error.isNotEmpty) _paragraph(_error),
          for (final section in sections)
            Padding(
              padding: const EdgeInsets.only(top: 18),
              child: SiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      textOf(section, 'title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 14),
                    for (final p in (section['paragraphs'] as List? ?? []))
                      _paragraph('$p'),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
