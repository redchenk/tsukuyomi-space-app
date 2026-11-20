import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import '../site/native_site_shell.dart';
import '../site/site_widgets.dart';
import 'drift_submissions.dart';
import 'drift_lantern_scene.dart';

class DriftPage extends StatefulWidget {
  const DriftPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
    this.path = '/drift',
    this.admin = false,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final String path;
  final bool admin;
  @override
  State<DriftPage> createState() => _DriftPageState();
}

class _DriftPageState extends State<DriftPage> with WidgetsBindingObserver {
  late final submissions = DriftSubmissions(c.storage);
  final draft = TextEditingController(), reply = TextEditingController();
  final replyDrafts = <String, String>{};
  final replied = <String>{};
  bool sealed = false;
  Map<String, dynamic>? thread, prompt, writingPrompt, pendingDaily;
  List<Map<String, dynamic>> bottles = [], moderationReplies = [];
  String owner = '', filter = 'all', notice = '', error = '', translated = '';
  String translationSource() => '${thread?['bottle']}:${thread?['replies']}';
  Future<void> _translate() async {
    if (thread == null || c.site is! SiteClient) return;
    final identity = owner, source = translationSource();
    final texts = [
      '${thread!['bottle']['content']}',
      for (final r in rowsOf(thread!['replies'])) '${r['content']}',
    ];
    final output = <String>[];
    for (var start = 0; start < texts.length; start += 8) {
      output.addAll(
        await (c.site as SiteClient).translatePrivate(
          c.settings.siteUrl,
          texts.sublist(start, (start + 8).clamp(0, texts.length)),
        ),
      );
      if (!mounted || identity != owner || source != translationSource()) {
        return;
      }
    }
    setState(() => translated = output.join('\n\n'));
  }

  int page = 1, pages = 1, epoch = 0, readEpoch = 0;
  bool loading = true,
      busy = false,
      writing = false,
      daily = false,
      sent = false;
  Timer? refresh;
  RoomController get c => widget.controller;
  bool get permitted =>
      c.account != null && (!widget.admin || c.account!.isAdministrator);
  String get lang => Localizations.localeOf(context).languageCode;
  @override
  void initState() {
    super.initState();
    owner = c.scope;
    c.addListener(_scope);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _scope() {
    if (owner == c.scope) return;
    owner = c.scope;
    epoch++;
    readEpoch++;
    refresh?.cancel();
    draft.clear();
    reply.clear();
    replyDrafts.clear();
    replied.clear();
    sealed = false;
    notice = '';
    pendingDaily = null;
    setState(() {
      thread = null;
      translated = '';
      prompt = null;
      writing = false;
      sent = false;
      bottles = [];
      busy = false;
      error = '';
    });
    _load();
  }

  Future<dynamic> _request(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final site = c.site, scope = c.scope;
    if (site is! SiteDataService) throw const ApiFailure('当前连接不支持星海来信');
    final response = await (site as SiteDataService).request(
      c.settings.siteUrl,
      method,
      path,
      body,
    );
    if (!mounted || scope != c.scope) throw const ApiFailure('账号已切换');
    return response['data'];
  }

  Future<void> _run(Future<void> Function() task) async {
    if (busy || !permitted) return;
    final current = epoch;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      await task();
    } catch (e) {
      if (mounted && current == epoch) {
        setState(() => error = e is ApiFailure ? e.message : '连接失败，请重试');
      }
    } finally {
      if (mounted && current == epoch) setState(() => busy = false);
    }
  }

  Future<void> _load() async {
    final current = epoch;
    if (!permitted) {
      if (mounted) setState(() => loading = false);
      return;
    }
    setState(() => loading = true);
    try {
      if (widget.admin) {
        final data = mapOf(await _request('GET', '/api/admin/drift'));
        if (current != epoch || !mounted) return;
        setState(() {
          bottles = rowsOf(data['bottles']);
          moderationReplies = rowsOf(data['replies']);
        });
      } else {
        final data = mapOf(
          await _request('GET', '/api/drift?page=$page&filter=$filter'),
        );
        if (current != epoch || !mounted) return;
        setState(() {
          bottles = rowsOf(data['items']);
          page = (data['page'] as num? ?? 1).toInt();
          pages = (data['totalPages'] as num? ?? 1).toInt();
        });
        prompt = mapOf(await _request('GET', '/api/drift/daily-prompt'));
        final bottle = Uri.parse(widget.path).queryParameters['bottle'];
        if (thread == null &&
            bottle != null &&
            RegExp(r'^[1-9][0-9]*$').hasMatch(bottle)) {
          await _open(bottle);
        }
      }
    } catch (e) {
      if (mounted && current == epoch) {
        setState(() => error = e is ApiFailure ? e.message : '无法加载来信');
      }
    } finally {
      if (mounted && current == epoch) setState(() => loading = false);
    }
  }

  Future<void> _open(String id) async {
    final request = ++readEpoch;
    final data = mapOf(
      await _request('GET', '/api/drift/${Uri.encodeComponent(id)}'),
    );
    if (!mounted || request != readEpoch) return;
    if (thread != null) replyDrafts['${thread!['bottle']['id']}'] = reply.text;
    setState(() {
      if (data['bottle'].toString() != thread?['bottle'].toString() ||
          data['replies'].toString() != thread?['replies'].toString()) {
        translated = '';
      }
      if ('${thread?['bottle']?['id']}' != id) sealed = false;
      thread = data;
      writing = false;
      reply.text = replyDrafts[id] ?? '';
    });
    refresh?.cancel();
    refresh = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!busy &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          thread != null) {
        unawaited(_open('${thread!['bottle']['id']}').catchError((_) {}));
      }
    });
  }

  Future<void> _write(bool daily) async {
    refresh?.cancel();
    if (daily) prompt = mapOf(await _request('GET', '/api/drift/daily-prompt'));
    if (!mounted) return;
    setState(() {
      this.daily = daily;
      writingPrompt = daily ? Map.of(prompt!) : null;
      writing = true;
      thread = null;
      sent = false;
    });
  }

  Future<void> _send() async {
    if (draft.text.trim().isEmpty) return;
    final promptDate = pendingDaily?['promptDate'] ?? writingPrompt?['date'];
    final promptId = pendingDaily?['promptId'] ?? writingPrompt?['id'];
    final scope = '$owner:${daily ? 'daily:$promptDate:$promptId' : 'bottle'}';
    var payload = daily ? pendingDaily : null;
    payload ??= await submissions.prepare(scope, {
      'content': draft.text.trim(),
      'language': lang,
      if (daily) 'promptDate': writingPrompt?['date'],
      if (daily) 'promptId': writingPrompt?['id'],
    });
    if (daily) pendingDaily = payload;
    dynamic result;
    try {
      result = await _request(
        'POST',
        daily ? '/api/drift/daily' : '/api/drift',
        payload,
      );
    } catch (e) {
      if (e is ApiFailure && e.status != null && e.status! < 500) {
        pendingDaily = null;
      }
      rethrow;
    }
    await submissions.complete(scope, '${payload['requestId']}');
    if (!mounted) return;
    setState(() {
      pendingDaily = null;
      draft.clear();
      writing = false;
      sent = true;
      filter = 'sent';
      page = 1;
      notice = '来信已放入湖中 · ${_status(mapOf(result))}';
    });
    await _load();
  }

  Future<void> _reply() async {
    final id = '${thread!['bottle']['id']}', content = reply.text.trim();
    if (content.isEmpty) return;
    final scope = '$owner:reply:$id', identity = owner;
    final payload = await submissions.prepare(scope, {
      'content': content,
      'language': lang,
    });
    if (!mounted ||
        identity != c.scope ||
        thread?['bottle']?['id'].toString() != id) {
      return;
    }
    final result = mapOf(
      await _request('POST', '/api/drift/$id/replies', payload),
    );
    await submissions.complete(scope, '${payload['requestId']}');
    if (!mounted || identity != owner) return;
    replied.add(id);
    replyDrafts.remove(id);
    final receipt = switch (result['status']) {
      'approved' => '回信已发送',
      'pending' => '回信已提交，审核通过后对方就能看到',
      'rejected' => '回信未通过审核，对方无法看到',
      _ => '回信已保存',
    };
    setState(() {
      if ('${thread?['bottle']?['id']}' == id) reply.clear();
      notice = receipt;
    });
    if ('${thread?['bottle']?['id']}' == id) {
      try {
        await _open(id);
      } catch (_) {
        if (mounted && identity == owner) {
          setState(() => notice = '$receipt · 往返信件暂时无法刷新');
        }
      }
    }
  }

  Future<void> _action(String action, String label) async {
    final id = '${thread!['bottle']['id']}';
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: const SiteText('确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const SiteText('确定'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _request('POST', '/api/drift/$id/$action');
    if (!mounted) return;
    readEpoch++;
    refresh?.cancel();
    setState(() {
      thread = null;
      if (action == 'return') {
        replyDrafts.remove(id);
        bottles.removeWhere((b) => '${b['id']}' == id);
      }
      notice = '$label · 已完成';
    });
    await _load();
  }

  String _status(Map b) => b['status'] == 'pending'
      ? '等待审核'
      : b['status'] == 'rejected'
      ? '未通过审核'
      : b['closed'] == 1 || b['closed'] == true
      ? '已结束'
      : b['recipient_id'] == null
      ? '正在漂流'
      : '已拾起';
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      refresh?.cancel();
    } else if (thread != null) {
      _open('${thread!['bottle']['id']}').catchError((_) {});
    }
  }

  @override
  void dispose() {
    epoch++;
    readEpoch++;
    refresh?.cancel();
    c.removeListener(_scope);
    WidgetsBinding.instance.removeObserver(this);
    draft.dispose();
    reply.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: widget.admin ? '来信审核' : '星海来信',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.admin) DriftLanternScene(sent: sent),
        const SizedBox(height: 16),
        if (loading) const LinearProgressIndicator(),
        if (notice.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(notice)),
        if (error.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(error)),
        if (!permitted)
          SiteCard(
            child: Column(
              children: [
                SiteText(
                  widget.admin ? '仅管理员可查看来信审核' : '登录后写信、拾起一封来信，或查看自己的信件。',
                ),
                TextButton(
                  onPressed: () => widget.onGo('/login?redirect=%2Fdrift'),
                  child: const SiteText('登录'),
                ),
              ],
            ),
          )
        else if (widget.admin) ...[
          for (final group in [
            ('bottles', bottles),
            ('replies', moderationReplies),
          ])
            for (final item in group.$2)
              SiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${item['content']}'),
                    Wrap(
                      children: [
                        for (final decision in [
                          ('approved', '通过'),
                          ('rejected', '拒绝'),
                        ])
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _run(() async {
                                    await _request(
                                      'POST',
                                      '/api/admin/drift/${group.$1}/${item['id']}',
                                      {'status': decision.$1},
                                    );
                                    await _load();
                                  }),
                            child: Text(decision.$2),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          if (bottles.isEmpty && moderationReplies.isEmpty)
            const SiteText('暂无待审核来信'),
        ] else ...[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: busy ? null : () => _run(() => _write(false)),
                child: const SiteText('写一封信'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => _run(() => _write(true)),
                child: const SiteText('今日命题'),
              ),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        final found = await _request('POST', '/api/drift/pick');
                        if (found == null) {
                          setState(() => notice = '湖面暂时没有新的来信');
                        } else {
                          await _open('${found['id']}');
                          if (mounted &&
                              '${thread?['bottle']?['id']}' ==
                                  '${found['id']}') {
                            setState(() => sealed = true);
                          }
                        }
                      }),
                child: const SiteText('拾起一封来信'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (writing)
            SiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SiteText(daily ? '今日命题' : '写给有缘人'),
                  if (daily)
                    Text(
                      '${writingPrompt?['text']?[lang] ?? writingPrompt?['text']?['zh'] ?? ''}',
                      style: const TextStyle(fontSize: 20),
                    ),
                  TextField(
                    controller: draft,
                    maxLines: 8,
                    maxLength: 2000,
                    readOnly: busy || pendingDaily != null,
                    decoration: const InputDecoration(hintText: '写下想说的话…'),
                  ),
                  if (pendingDaily != null)
                    const SiteText('上次提交结果尚未确认，重试将查询同一封来信。'),
                  FilledButton(
                    onPressed: busy ? null : () => _run(_send),
                    child: SiteText(pendingDaily != null ? '重试确认' : '放灯入湖'),
                  ),
                ],
              ),
            ),
          if (thread != null) _thread(),
          if (!writing && thread == null) ...[
            Wrap(
              spacing: 8,
              children: [
                for (final f in [
                  ('all', '全部来信'),
                  ('sent', '寄出的信'),
                  ('received', '拾起的信'),
                ])
                  ChoiceChip(
                    label: SiteText(f.$2),
                    selected: filter == f.$1,
                    onSelected: busy
                        ? null
                        : (_) => _run(() async {
                            setState(() {
                              filter = f.$1;
                              page = 1;
                            });
                            await _load();
                          }),
                  ),
              ],
            ),
            if (bottles.isEmpty && !loading)
              const Padding(
                padding: EdgeInsets.all(28),
                child: SiteText('还没有来信，先写下一句心事吧。'),
              ),
            for (final bottle in bottles)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SiteCard(
                  child: ListTile(
                    title: Text(
                      '${bottle['content']}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${_status(bottle)} · ${bottle['created_at'] ?? ''}',
                    ),
                    onTap: busy
                        ? null
                        : () => _run(() => _open('${bottle['id']}')),
                  ),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: busy || page <= 1
                      ? null
                      : () => _run(() async {
                          page--;
                          await _load();
                        }),
                  child: const SiteText('上一页'),
                ),
                Text('$page / $pages'),
                TextButton(
                  onPressed: busy || page >= pages
                      ? null
                      : () => _run(() async {
                          page++;
                          await _load();
                        }),
                  child: const SiteText('下一页'),
                ),
              ],
            ),
          ],
        ],
      ],
    ),
  );
  Widget _thread() {
    final bottle = mapOf(thread!['bottle']),
        replies = rowsOf(thread!['replies']),
        peer = mapOf(thread!['peer']);
    final canReply =
        bottle['status'] == 'approved' &&
        bottle['recipient_id'] != null &&
        bottle['closed'] != 1 &&
        bottle['closed'] != true &&
        thread!['blocked'] != true;
    final canReturn =
        canReply &&
        '${bottle['recipient_id']}' == c.account?.id &&
        replies.isEmpty &&
        !replied.contains('${bottle['id']}');
    if (sealed) {
      return SiteCard(
        child: Column(
          children: [
            Image.asset(
              'assets/images/drift/lantern/paper-lantern.webp',
              height: 120,
            ),
            const SiteText('拾到了一封来信'),
            Wrap(
              spacing: 12,
              children: [
                if (canReturn)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _run(() => _action('return', '放回湖中')),
                    child: const SiteText('放回湖中'),
                  ),
                FilledButton(
                  onPressed: () => setState(() => sealed = false),
                  child: const SiteText('打开来信'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    return SiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: SiteText('月光下的来信', style: TextStyle(fontSize: 22)),
              ),
              IconButton(
                tooltip: '收好来信',
                onPressed: () {
                  refresh?.cancel();
                  readEpoch++;
                  replyDrafts['${bottle['id']}'] = reply.text;
                  setState(() => thread = null);
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          SelectableText('${bottle['content']}'),
          Text(_status(bottle)),
          for (final r in replies)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${r['user_id']}' == c.account?.id
                        ? '我'
                        : '${peer['nickname'] ?? '有缘人'}',
                  ),
                  SelectableText('${r['content']}'),
                  if (r['status'] != 'approved') Text(_status(r)),
                ],
              ),
            ),
          if (c.site is SiteClient &&
              (c.site as SiteClient).translatesContent(c.settings.siteUrl))
            ExpansionTile(
              title: const Text('Translate to English'),
              children: [
                const Text(
                  'Translate this private conversation on request. Original messages remain unchanged.',
                ),
                TextButton(
                  onPressed: busy ? null : () => _run(_translate),
                  child: const Text('Translate'),
                ),
                if (translated.isNotEmpty) SelectableText(translated),
              ],
            ),
          if (canReply) ...[
            TextField(
              controller: reply,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '回信'),
            ),
            FilledButton(
              onPressed: busy ? null : () => _run(_reply),
              child: const SiteText('寄出回信'),
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() => _open('${bottle['id']}')),
                child: const SiteText('刷新'),
              ),
              if (peer['id'] != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          await _request(
                            'POST',
                            '/api/user/follow/${Uri.encodeComponent('${peer['id']}')}',
                          );
                          setState(() => notice = '已关注');
                        }),
                  child: const SiteText('关注对方'),
                ),
              if (canReturn)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() => _action('return', '放回湖中')),
                  child: const SiteText('放回湖中'),
                ),
              for (final a in [
                ('close', '结束通信'),
                ('report', '举报'),
                if (peer['id'] != null) ('block', '屏蔽对方'),
              ])
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() => _action(a.$1, a.$2)),
                  child: SiteText(a.$2),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
