import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_files.dart';
import '../../core/site_client.dart';
import '../room/room_controller.dart';
import 'native_site_shell.dart';
import 'site_widgets.dart';

class CommunityAdminPage extends StatelessWidget {
  const CommunityAdminPage({
    super.key,
    required this.room,
    required this.path,
    required this.onGo,
    this.onTheme,
  });
  final RoomController room;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: room,
    builder: (context, _) {
      final site = room.site,
          terminal = (site.cookie ?? '').contains('tsukuyomi_admin_session=');
      final title = path.endsWith('/play-testing')
          ? 'Google Play 测试申请'
          : '注销申请工作台';
      return NativeSiteShell(
        controller: room,
        title: title,
        onTheme: onTheme,
        onGo: onGo,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SitePageHero(
              title: title,
              kicker: path.endsWith('/play-testing')
                  ? 'GOOGLE PLAY · CLOSED TEST'
                  : 'TSUKUYOMI · PRIVATE REQUESTS',
              subtitle: '仅超级管理员可查看与处理。',
            ),
            Wrap(
              children: [
                TextButton(
                  onPressed: () => onGo('/admin'),
                  child: const Text('返回管理中心'),
                ),
                TextButton(
                  onPressed: () => onGo('/terminal'),
                  child: const Text('数据终端'),
                ),
              ],
            ),
            if (room.sessionExpired ||
                (room.account?.role != 'super_admin' && !terminal))
              const Text('请先在数据终端登录超级管理员账号，再返回本页。')
            else
              _AdminContents(
                key: ValueKey((
                  room.settings.siteUrl,
                  room.account?.id,
                  terminal,
                  site is SiteClient ? site.sessionRevision : 0,
                  path,
                )),
                room: room,
                path: path,
              ),
          ],
        ),
      );
    },
  );
}

class _AdminContents extends StatefulWidget {
  const _AdminContents({super.key, required this.room, required this.path});
  final RoomController room;
  final String path;
  @override
  State<_AdminContents> createState() => _AdminState();
}

class _AdminState extends State<_AdminContents> {
  final search = TextEditingController(),
      join = TextEditingController(),
      mailLink = TextEditingController(),
      previewLink = TextEditingController();
  final receipts = <String, String>{}, checks = <String, Set<String>>{};
  static const checklist = {
    'identity': '已通过绑定邮箱核验身份和范围',
    'balance': '已核对余额、订单、退款或法定留存',
    'content': '已清理公开文章、评论、作品与关联',
    'privateData': '已清理聊天、记忆、日记、登录绑定及账号',
    'storage': '已清理附件、对象版本及 CDN 缓存',
    'processors': '已处理向量库、独立 API 服务及第三方副本',
    'backups': '已清理或隔离备份，并登记恢复后重新删除安排',
    'notification': '已向核验邮箱发送完成回执及必要留存范围、依据和期限',
  };
  static const statuses = {
    'pending': '待核验',
    'processing': '处理中',
    'completed': '已完成',
    'cancelled': '已撤回',
  };
  static const playStatuses = {
    'all': '全部',
    'pending': '待处理',
    'invited': '已发邀请',
  };
  bool get play => widget.path.endsWith('/play-testing');
  late String filter = play ? 'all' : 'pending';
  late final String origin = widget.room.settings.siteUrl;
  String error = '', notice = '', savedMail = '', deleteId = '';
  Map<String, dynamic> result = {}, preview = {};
  bool busy = false,
      authorized = false,
      registration = false,
      published = false,
      confirmed = false;
  int get page => (result['page'] as num?)?.toInt() ?? 1;
  String query(int page) => Uri(
    queryParameters: {
      'status': filter,
      'page': '$page',
      if (play) 'search': search.text.trim(),
    },
  ).query;
  @override
  void initState() {
    super.initState();
    run(() => load(1));
  }

  @override
  void dispose() {
    for (final c in [search, join, mailLink, previewLink]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<dynamic> request(
    String suffix, [
    Map<String, dynamic>? body,
    String method = 'POST',
  ]) async {
    if (!mounted || origin != widget.room.settings.siteUrl) {
      throw const ApiFailure('身份已更改');
    }
    final response = await (widget.room.site as SiteDataService).request(
      origin,
      body == null ? 'GET' : method,
      '/api${widget.path}$suffix',
      body,
    );
    if (!mounted) throw const ApiFailure('身份已更改');
    return response['data'];
  }

  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
      notice = '';
    });
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiFailure && {401, 403}.contains(e.status)) {
            authorized = false;
            result = {};
            preview = {};
            receipts.clear();
            checks.clear();
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load(int target) async {
    final results = await Future.wait([
      request('?${query(target)}'),
      if (play) request('/settings'),
      if (play) request('/invitation-settings'),
    ]);
    if (!mounted) return;
    setState(() {
      result = mapOf(results.first);
      authorized = true;
      deleteId = '';
      if (play) {
        final settings = mapOf(results[1]);
        registration = settings['registrationOpen'] == true;
        join.text = textOf(settings, 'joinUrl');
        published = false;
        savedMail = textOf(mapOf(results[2]), 'actionUrl');
        mailLink.text = savedMail;
      }
    });
  }

  Future<void> inspect(String id) async {
    final next = mapOf(
      await request('/${Uri.encodeComponent(id)}/invitation-preview'),
    );
    if (mounted) {
      setState(() {
        preview = next;
        confirmed = false;
        previewLink.text = textOf(next, 'actionUrl');
      });
    }
  }

  Future<void> saveLink(bool inside) async {
    await request('/invitation-settings', {
      'actionUrl': (inside ? previewLink : mailLink).text.trim(),
      'previousActionUrl': inside ? preview['actionUrl'] : savedMail,
    });
    if (!mounted) return;
    if (inside) await inspect('${preview['applicationId']}');
    await load(page);
    notice = '邀请邮件链接已保存';
  }

  Future<void> send() async {
    final value = Map.of(preview), id = '${value['applicationId']}';
    if (!confirmed ||
        value['configured'] != true ||
        previewLink.text.trim() != value['actionUrl'] ||
        {
          'sent',
          'sending',
          'unknown',
        }.contains(mapOf(value['delivery'])['status'])) {
      return;
    }
    try {
      final data = mapOf(
        await request('/${Uri.encodeComponent(id)}/invite', {
          'confirmation': 'SEND_PLAY_INVITATION',
          'confirmTesterAdded': true,
          for (final k in [
            'email',
            'version',
            'attemptId',
            'previousAttemptId',
          ])
            k: value[k],
        }),
      );
      if (!mounted) return;
      preview = {};
      await load(page);
      notice = data['alreadySent'] == true
          ? '邀请已发送，本次未重复发送。'
          : textOf(mapOf(data['delivery']), 'result');
    } catch (_) {
      if (mounted) {
        confirmed = false;
        preview = {};
        await inspect(id);
        await load(page);
      }
      rethrow;
    }
  }

  Future<void> export() async {
    final csv = await request('/export?${query(page)}');
    if (!mounted || csv is! String) return;
    final saved = await exportRoomFile(
      context,
      Uint8List.fromList(utf8.encode(csv)),
      'google-play-testers.csv',
      'text/csv',
    );
    if (mounted && saved) notice = '已导出当前筛选的邮箱。';
  }

  Future<void> update(Map row, String next) async {
    final id = '${row['id']}';
    await request('/${Uri.encodeComponent(id)}/status', {
      'status': next,
      'checklist': {for (final k in checks[id] ?? <String>{}) k: true},
      'resolution': receipts[id] ?? '',
    });
    if (!mounted) return;
    checks.remove(id);
    receipts.remove(id);
    await load(page);
  }

  Widget button(
    String label,
    Future<void> Function() action, {
    bool enabled = true,
  }) => OutlinedButton(
    onPressed: busy || !enabled ? null : () => run(action),
    child: Text(label),
  );
  Widget field(
    String label,
    TextEditingController ctrl, {
    int max = 300,
    ValueChanged<String>? changed,
  }) => TextField(
    controller: ctrl,
    enabled: !busy,
    maxLength: max,
    onChanged: changed,
    decoration: InputDecoration(labelText: label, counterText: ''),
  );
  Widget check(String label, bool value, ValueChanged<bool> select) =>
      CheckboxListTile(
        title: Text(label),
        value: value,
        onChanged: busy ? null : (v) => setState(() => select(v == true)),
      );
  Widget deletion(Map row) {
    final id = '${row['id']}',
        selected = checks.putIfAbsent(id, () => {}),
        status = row['status'];
    return NativeSiteSection(
      title: "${row['username'] ?? '账号已移除'} · ${statuses[status] ?? status}",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('编号 $id\n核验邮箱 ${row['email'] ?? '请查阅受控处理回执'}'),
          Text(
            '收到 ${dateText(row['requested_at'])} · 预计处理 ${dateText(row['due_at'])}',
          ),
          if ({'pending', 'processing'}.contains(status) &&
              (DateTime.tryParse('${row['due_at']}')
                      ?.isBefore(DateTime.now()) ??
                  false))
            const Text('已逾期，请优先联系'),
          if (status == 'pending')
            button('开始核验处理', () => update(row, 'processing')),
          if (status == 'processing') ...[
            const Text('先保存受控的数据清理清单，再处理账号。请勿填写密码、密钥、身份证或聊天内容。'),
            for (final c in checklist.entries)
              check(c.value, selected.contains(c.key), (v) {
                if (v) {
                  selected.add(c.key);
                } else {
                  selected.remove(c.key);
                }
              }),
            TextFormField(
              key: ValueKey(id),
              initialValue: receipts[id] ?? '',
              enabled: !busy,
              maxLength: 2000,
              onChanged: (s) => setState(() => receipts[id] = s),
              decoration: const InputDecoration(
                labelText: '处理回执摘要（至少 10 字，说明保留依据与期限）',
              ),
            ),
            if (row['user_id'] != null) const Text('账号仍存在，清理前无法登记完成。'),
            button(
              '登记已核验完成',
              () => update(row, 'completed'),
              enabled:
                  row['user_id'] == null &&
                  selected.length == checklist.length &&
                  (receipts[id] ?? '').trim().length >= 10,
            ),
          ] else if (textOf(row, 'resolution').isNotEmpty)
            Text(textOf(row, 'resolution')),
        ],
      ),
    );
  }

  Widget application(Map row) {
    final id = '${row['id']}',
        delivery = mapOf(row['delivery']),
        prev = mapOf(row['previousDelivery']);
    return NativeSiteSection(
      title: "${row['email']} · ${playStatuses[row['status']] ?? ''}",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "${row['device'] ?? '未填写设备'} · ${row['android_version'] ?? '未填写 Android 版本'}",
          ),
          Text(
            '申请时间 ${dateText(row['created_at'])} · 同意说明版本 ${row['consent_version']}',
          ),
          if (delivery.isNotEmpty)
            Text('${delivery['status']} · ${delivery['result'] ?? ''}'),
          if (prev.isNotEmpty)
            Text('此前邀请使用其他链接 ${prev['action_url']} · ${prev['status']}'),
          Wrap(
            spacing: 8,
            children: [
              button(
                '查看邀请邮件',
                () => inspect(id),
                enabled: !{'sending', 'unknown'}.contains(delivery['status']),
              ),
              TextButton(
                onPressed: busy || delivery['status'] == 'sending'
                    ? null
                    : () => setState(() => deleteId = id),
                child: const Text('删除申请资料'),
              ),
            ],
          ),
          if (deleteId == id) ...[
            Text("永久删除 ${row['email']} 的申请及设备信息？请先核验删除请求或确认是无效记录。"),
            Wrap(
              children: [
                TextButton(
                  onPressed: busy ? null : () => setState(() => deleteId = ''),
                  child: const Text('取消'),
                ),
                button('确认删除申请资料', () async {
                  await request('/${Uri.encodeComponent(id)}', {
                    'confirmation': 'DELETE_APPLICATION',
                  }, 'DELETE');
                  if (mounted) {
                    preview = {};
                    await load(page);
                  }
                }),
              ],
            ),
          ],
          if ('${preview['applicationId']}' == id) ...[
            Text('确认测试邀请邮件', style: Theme.of(context).textTheme.titleLarge),
            Text('${preview['email']} · ${preview['subject'] ?? ''}'),
            Text(
              preview['track'] == 'internal'
                  ? '内部测试邀请 · 不计入封闭测试的连续 14 天'
                  : '封闭测试邀请 · 曾加入内部测试的用户需先退出内部测试',
            ),
            SelectableText(
              textOf(preview, 'text', plainText(textOf(preview, 'html'))),
            ),
            field(
              '当前邀请链接',
              previewLink,
              changed: (_) => setState(() => confirmed = false),
            ),
            button(
              '保存链接并更新预览',
              () => saveLink(true),
              enabled: previewLink.text.trim() != preview['actionUrl'],
            ),
            if (preview['configured'] == true &&
                !{
                  'sent',
                  'sending',
                  'unknown',
                }.contains(mapOf(preview['delivery'])['status'])) ...[
              check(
                '我已将此邮箱加入该链接对应的 Google Play 测试名单，确认向该邮箱发送以上邀请。',
                confirmed,
                (v) => confirmed = v,
              ),
              button(
                '确认发送邀请邮件',
                send,
                enabled:
                    confirmed &&
                    previewLink.text.trim() == preview['actionUrl'],
              ),
            ] else
              Text(
                preview['configured'] == true
                    ? textOf(mapOf(preview['delivery']), 'result')
                    : '邮件通道未配置，暂时无法发送。',
              ),
            TextButton(
              onPressed: busy ? null : () => setState(() => preview = {}),
              child: const Text('关闭预览'),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final options = play ? playStatuses : statuses;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error.isNotEmpty) Text(error),
        if (notice.isNotEmpty) Text(notice),
        if (busy) const LinearProgressIndicator(),
        if (!authorized)
          button('重新读取', () => load(1))
        else ...[
          if (play) ...[
            NativeSiteSection(
              title: '邀请邮件链接',
              child: Column(
                children: [
                  field(
                    'Google Play 邀请链接',
                    mailLink,
                    changed: (_) => setState(() {}),
                  ),
                  button(
                    '保存邀请链接',
                    () => saveLink(false),
                    enabled: mailLink.text.trim() != savedMail,
                  ),
                ],
              ),
            ),
            ExpansionTile(
              title: const Text('报名开关与封闭测试公开链接'),
              children: [
                check('开放报名', registration, (v) => registration = v),
                field(
                  '封闭测试加入链接（未就绪时留空）',
                  join,
                  changed: (_) => setState(() => published = false),
                ),
                check(
                  '我已确认封闭测试版本发布、名单已配置，并验证此链接可用。',
                  published,
                  (v) => published = v,
                ),
                button('保存设置', () async {
                  await request('/settings', {
                    'registrationOpen': registration,
                    'joinUrl': join.text.trim(),
                    'confirmPublished': published,
                  });
                  if (mounted) await load(page);
                }, enabled: join.text.trim().isEmpty || published),
              ],
            ),
            field('筛选邮箱 / 设备', search, max: 100),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                value: filter,
                items: [
                  for (final e in options.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: busy
                    ? null
                    : (v) {
                        if (v != null) {
                          filter = v;
                          preview = {};
                          run(() => load(1));
                        }
                      },
              ),
              button(play ? '查询' : '刷新', () => load(1)),
              if (play) button('导出筛选邮箱', export),
              Text("共 ${result['total'] ?? 0} 条"),
            ],
          ),
          if (rowsOf(result['items']).isEmpty && !busy) const Text('暂无此条件的申请。'),
          for (final row in rowsOf(result['items']))
            play ? application(row) : deletion(row),
          Wrap(
            spacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              button('上一页', () => load(page - 1), enabled: page > 1),
              Text("$page / ${result['totalPages'] ?? 1}"),
              button(
                '下一页',
                () => load(page + 1),
                enabled: page < (result['totalPages'] ?? 1),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
