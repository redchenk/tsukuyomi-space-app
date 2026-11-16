import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../../core/models.dart';
import '../../core/site_localization.dart';
import '../drift/drift_submissions.dart';
import 'management_service.dart';
import 'site_widgets.dart';

class MailCampaignManager extends StatefulWidget {
  const MailCampaignManager({super.key, required this.api});
  final ManagementService api;
  @override
  State<MailCampaignManager> createState() => _MailCampaignManagerState();
}

class _MailCampaignManagerState extends State<MailCampaignManager>
    with WidgetsBindingObserver {
  final subject = TextEditingController(),
      body = TextEditingController(),
      actionUrl = TextEditingController(),
      actionLabel = TextEditingController(text: '查看详情'),
      search = TextEditingController();
  final selected = <String, Map<String, dynamic>>{};
  Map<String, dynamic> recipients = {}, detail = {};
  List<Map<String, dynamic>> history = [];
  String mode = 'selected',
      role = 'all',
      error = '',
      notice = '',
      pendingFingerprint = '',
      pendingId = '';
  bool busy = false, configured = false, foreground = true;
  int epoch = 0, page = 1, detailPage = 1;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (foreground &&
          !busy &&
          history.any((c) => ['queued', 'running'].contains(c['status']))) {
        refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
  }

  @override
  void dispose() {
    epoch++;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    for (final c in [subject, body, actionUrl, actionLabel, search]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<dynamic> request(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) => widget.api.data(method, '/mail-campaigns$path', data);
  Future<void> run(Future<void> Function(int) action) async {
    if (busy) return;
    final current = ++epoch;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action(current);
    } catch (e) {
      if (mounted && epoch == current) {
        setState(() => error = e is ApiFailure ? e.message : '操作失败，请刷新记录核实');
      }
    } finally {
      if (mounted && epoch == current) setState(() => busy = false);
    }
  }

  Future<void> refresh() => run((current) async {
    final result = await request('GET', '');
    final users = await request(
      'GET',
      '/recipients?${Uri(queryParameters: {'search': search.text.trim(), 'role': role, 'page': '$page'}).query}',
    );
    final latest = detail.isEmpty
        ? null
        : await request(
            'GET',
            '/${Uri.encodeComponent('${detail['campaign']['id']}')}?page=$detailPage',
          );
    if (!mounted || current != epoch) return;
    setState(() {
      configured = result['configured'] == true;
      history = rowsOf(result['campaigns']);
      recipients = Map.from(users);
      if (latest != null) detail = Map.from(latest);
    });
  });
  Future<void> loadDetail(String id, [int next = 1]) => run((current) async {
    final result = await request(
      'GET',
      '/${Uri.encodeComponent(id)}?page=$next',
    );
    if (mounted && current == epoch) {
      setState(() {
        detail = Map.from(result);
        detailPage = next;
      });
    }
  });
  Future<void> prepare() => run((current) async {
    if (subject.text.trim().isEmpty ||
        body.text.trim().isEmpty ||
        (mode == 'selected' && selected.isEmpty)) {
      throw const ApiFailure('请填写主题、正文并选择收件人');
    }
    final payload = {
      'subject': subject.text.trim(),
      'body': body.text.trim(),
      'actionUrl': actionUrl.text.trim(),
      'actionLabel': actionLabel.text.trim(),
      'audience': mode == 'filtered'
          ? {'mode': mode, 'search': search.text.trim(), 'role': role}
          : {'mode': mode, 'userIds': selected.keys.toList()},
    };
    final fingerprint = jsonEncode(payload);
    if (pendingFingerprint != fingerprint) {
      pendingFingerprint = fingerprint;
      pendingId = DriftSubmissions.uuid();
    }
    final preview = Map<String, dynamic>.from(
      await request('POST', '/preview', {...payload, 'id': pendingId}),
    );
    if (!mounted || current != epoch) return;
    // Preview is a server-owned immutable batch. Never send from the editable form.
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const SiteText('确认邮件与收件人'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('本批将发送给 ${preview['campaign']['total']} 个邮箱'),
                ExpansionTile(
                  title: const SiteText('查看收件邮箱（前 20 个）'),
                  children: [
                    for (final user in rowsOf(preview['recipients']))
                      Text('${user['email']}'),
                  ],
                ),
                HtmlWidget(
                  '${preview['html'] ?? ''}',
                  onTapUrl: (_) async => true,
                  customWidgetBuilder: (element) =>
                      const {
                        'img',
                        'iframe',
                        'script',
                        'object',
                        'embed',
                      }.contains(element.localName)
                      ? const SizedBox.shrink()
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const SiteText('返回编辑'),
          ),
          FilledButton(
            onPressed: configured ? () => Navigator.pop(context, true) : null,
            child: Text('确认发送给 ${preview['campaign']['total']} 个邮箱'),
          ),
        ],
      ),
    );
    if (!mounted || current != epoch || confirmed != true) return;
    final campaign = await request(
      'POST',
      '/${Uri.encodeComponent('${preview['campaign']['id']}')}/send',
      {},
    );
    if (!mounted || current != epoch) return;
    setState(() {
      notice = '已提交 ${campaign['total']} 个邮箱，发送将在后台继续。';
      pendingFingerprint = '';
      pendingId = '';
    });
    final result = await request('GET', '');
    if (mounted && current == epoch) {
      setState(() => history = rowsOf(result['campaigns']));
    }
  });
  Future<void> cancel(Map<String, dynamic> campaign) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const SiteText('停止剩余发送？'),
        content: Text('${campaign['subject']}\n正在发送的邮件会记录最终结果。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const SiteText('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const SiteText('停止剩余发送'),
          ),
        ],
      ),
    );
    if (!mounted || confirm != true) return;
    await run((current) async {
      await request(
        'POST',
        '/${Uri.encodeComponent('${campaign['id']}')}/cancel',
        {},
      );
      final result = await request('GET', '');
      if (mounted && current == epoch) {
        setState(() => history = rowsOf(result['campaigns']));
      }
    });
  }

  String status(dynamic v) =>
      const {
        'draft': '待确认',
        'queued': '排队中',
        'running': '发送中',
        'completed': '已结束',
        'cancelled': '已取消',
        'pending': '待发送',
        'sending': '发送中',
        'sent': '已提交邮件服务',
        'failed': '发送失败',
        'unknown': '待核实',
        'skipped': '已跳过',
      }[v] ??
      '$v';
  Widget pages(int current, int count, ValueChanged<int> change) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      IconButton(
        onPressed: busy || current <= 1 ? null : () => change(current - 1),
        icon: const Icon(Icons.chevron_left),
      ),
      Text('$current / ${count < 1 ? 1 : count}'),
      IconButton(
        onPressed: busy || current >= count ? null : () => change(current + 1),
        icon: const Icon(Icons.chevron_right),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SiteText('邮件群发', style: TextStyle(fontSize: 22)),
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (notice.isNotEmpty) Text(notice),
        SiteText(configured ? '邮件通道已就绪 · 使用网站统一邮件样式' : '邮件通道未配置，仍可编辑和预览'),
        Wrap(
          spacing: 8,
          children: [
            for (final m in [('selected', '勾选用户'), ('filtered', '群发给全部匹配用户')])
              ChoiceChip(
                label: SiteText(m.$2),
                selected: mode == m.$1,
                onSelected: busy ? null : (_) => setState(() => mode = m.$1),
              ),
          ],
        ),
        TextField(
          controller: search,
          enabled: !busy,
          maxLength: 120,
          decoration: const InputDecoration(labelText: '昵称、用户名、邮箱或 ID'),
          onSubmitted: (_) {
            page = 1;
            refresh();
          },
        ),
        DropdownButtonFormField<String>(
          initialValue: role,
          decoration: const InputDecoration(labelText: '用户角色'),
          items: [
            for (final r in [
              ('all', '所有角色'),
              ('user', '普通用户'),
              ('admin', '管理员'),
            ])
              DropdownMenuItem(value: r.$1, child: SiteText(r.$2)),
          ],
          onChanged: busy
              ? null
              : (v) {
                  setState(() {
                    role = v!;
                    page = 1;
                  });
                  refresh();
                },
        ),
        TextButton(
          onPressed: busy
              ? null
              : () {
                  page = 1;
                  refresh();
                },
          child: const SiteText('搜索用户'),
        ),
        Text('匹配 ${recipients['total'] ?? 0} 名用户 · 已勾选 ${selected.length} 人'),
        if (mode == 'filtered') const SiteText('将发送给全部匹配用户，包含其他分页；相同邮箱只发送一封。'),
        for (final user in rowsOf(recipients['items']))
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${user['nickname'] ?? user['username']}'),
            subtitle: Text('${user['email']}'),
            value: selected.containsKey('${user['id']}'),
            onChanged: busy || mode != 'selected'
                ? null
                : (v) => setState(() {
                    if (v == true) {
                      selected['${user['id']}'] = user;
                    } else {
                      selected.remove('${user['id']}');
                    }
                  }),
          ),
        pages(page, recipients['totalPages'] as int? ?? 1, (v) {
          page = v;
          refresh();
        }),
        if (selected.isNotEmpty)
          ExpansionTile(
            title: Text('已勾选 ${selected.length} 人（跨页保留）'),
            children: [
              for (final user in selected.values.toList())
                ListTile(
                  title: Text('${user['email']}'),
                  trailing: IconButton(
                    onPressed: busy
                        ? null
                        : () =>
                              setState(() => selected.remove('${user['id']}')),
                    icon: const Icon(Icons.close),
                  ),
                ),
            ],
          ),
        TextField(
          controller: subject,
          enabled: !busy,
          maxLength: 120,
          decoration: const InputDecoration(labelText: '邮件主题'),
        ),
        TextField(
          controller: body,
          enabled: !busy,
          maxLength: 10000,
          minLines: 6,
          maxLines: 16,
          decoration: const InputDecoration(labelText: '邮件正文'),
        ),
        TextField(
          controller: actionUrl,
          enabled: !busy,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: '按钮链接（选填）'),
        ),
        TextField(
          controller: actionLabel,
          enabled: !busy,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '按钮文字'),
        ),
        FilledButton(
          onPressed: busy ? null : prepare,
          child: const SiteText('预览并确认收件人'),
        ),
        TextButton(
          onPressed: busy ? null : refresh,
          child: const SiteText('刷新发送记录'),
        ),
        for (final campaign in history)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${campaign['subject']}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '${status(campaign['status'])} · ${campaign['total']} 个邮箱',
                ),
                Text(
                  '已提交 ${campaign['counts']?['sent'] ?? 0} · 失败 ${campaign['counts']?['failed'] ?? 0} · 待核实 ${campaign['counts']?['unknown'] ?? 0}',
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => loadDetail('${campaign['id']}'),
                      child: const SiteText('查看明细'),
                    ),
                    if (['queued', 'running'].contains(campaign['status']))
                      TextButton(
                        onPressed: busy ? null : () => cancel(campaign),
                        child: const SiteText('停止剩余发送'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (detail.isNotEmpty) ...[
          Text('${detail['campaign']['subject']} · 发送明细'),
          for (final recipient in rowsOf(detail['recipients']))
            ListTile(
              title: Text('${recipient['email']}'),
              subtitle: Text(
                '${status(recipient['status'])} ${recipient['result'] ?? ''}',
              ),
            ),
          pages(
            detailPage,
            ((detail['campaign']['total'] as num) / 20).ceil(),
            (v) => loadDetail('${detail['campaign']['id']}', v),
          ),
        ],
      ],
    ),
  );
}
