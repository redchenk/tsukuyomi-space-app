import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../../core/room_files.dart';
import '../settings/room_memory_manager.dart';
import '../site/site_widgets.dart';
import 'room_controller.dart';

class RoomDiaryPanel extends StatefulWidget {
  const RoomDiaryPanel({
    super.key,
    required this.controller,
    this.settingsMode = false,
  });
  final RoomController controller;
  final bool settingsMode;
  @override
  State<RoomDiaryPanel> createState() => _RoomDiaryPanelState();
}

class _RoomDiaryPanelState extends State<RoomDiaryPanel> {
  RoomArchive get archive => widget.controller.workspace.archive;
  String? selected;
  String notice = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(archive.sync());
  }

  Future<void> _run(Future<void> Function() task) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await task();
    } catch (e) {
      if (mounted) {
        setState(
          () => notice = e is ApiFailure
              ? e.message
              : e is FormatException
              ? e.message
              : '操作失败，本机存档已保留',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export() async {
    final now = DateTime.now();
    final ok = await exportRoomFile(
      context,
      Uint8List.fromList(utf8.encode(archive.exportText())),
      'tsukuyomi-diary-${now.year}${now.month}${now.day}.json',
      'application/json',
    );
    if (mounted) setState(() => notice = ok ? '存档已导出' : '已取消导出');
  }

  Future<void> _import() async {
    final scope = widget.controller.scope;
    final text = await importRoomFile();
    if (text == null || !mounted) return;
    if (!await roomConfirm(
      context,
      '导入日记与人设存档？',
      '将合并日记与人设，保留存档的其他字段；登录后继续与云端同步。',
    )) {
      return;
    }
    if (scope != widget.controller.scope) throw const ApiFailure('账号已切换，请重新导入');
    await archive.importText(text);
    await archive.sync();
    if (mounted) setState(() => notice = '已导入存档');
  }

  Future<void> _persona() async {
    final scope = widget.controller.scope;
    final value = archive.personaData,
        fields = {
          for (final k in [
            'name',
            'description',
            'personality',
            'scenario',
            'creator_notes',
            'tags',
          ])
            k: TextEditingController(
              text: value[k] is List
                  ? (value[k] as List).join(', ')
                  : '${value[k] ?? ''}',
            ),
        };
    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('编辑日记人设'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '只影响日记作者，聊天中的八千代保持不变。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  for (final e in fields.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: TextField(
                        controller: e.value,
                        minLines: ['name', 'tags'].contains(e.key) ? 1 : 3,
                        maxLines: ['name', 'tags'].contains(e.key) ? 1 : 6,
                        decoration: InputDecoration(
                          labelText: const {
                            'name': '角色名',
                            'description': '描述',
                            'personality': '性格',
                            'scenario': '场景',
                            'creator_notes': '补充设定',
                            'tags': '标签',
                          }[e.key],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存人设'),
            ),
          ],
        ),
      );
      if (result == true) {
        if (scope != widget.controller.scope) {
          throw const ApiFailure('账号已切换，请重新编辑');
        }
        if (fields['name']!.text.trim().isEmpty) {
          throw const ApiFailure('角色名不能为空');
        }
        await archive.savePersona({
          for (final e in fields.entries)
            e.key: e.key == 'tags'
                ? e.value.text
                      .split(RegExp('[,，]'))
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList()
                : e.value.text,
        });
        await archive.sync();
      }
    } finally {
      for (final c in fields.values) {
        c.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: archive,
    builder: (context, _) {
      final entries = archive.entries;
      final entry =
          entries.where((v) => v['diaryId'] == selected).firstOrNull ??
          entries.lastOrNull;
      final stats = jsonMap(
        jsonMap(archive.data['gameData'])['characterStats'],
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${archive.personaData['name'] ?? '角色'}的日记',
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            '${entries.length} 篇日记 · 好感度 ${stats['affection'] ?? 0} · 存档 ${archive.archive['slotId']}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          Text(archive.status, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 18),
          DropdownButtonFormField<String>(
            key: ValueKey(archive.activeId),
            initialValue: archive.prompts.containsKey(archive.activeId)
                ? archive.activeId
                : archive.prompts.keys.first,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '日记作者人设'),
            items: archive.prompts.entries
                .map(
                  (v) => DropdownMenuItem(
                    value: v.key,
                    child: Text(
                      '${jsonMap(jsonMap(v.value)['data'])['name'] ?? v.key}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (id) => _run(() async {
                    await archive.selectPersona(id!);
                    await archive.sync();
                  }),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : () => _run(_persona),
                child: const Text('编辑人设'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => _run(() => archive.sync()),
                child: const Text('同步'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => _run(_export),
                child: const Text('导出存档'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => _run(_import),
                child: const Text('导入存档'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        if (await roomConfirm(
                          context,
                          '清空全部日记？',
                          '此操作会同步到网站，无法恢复。人设不受影响，建议先导出备份。',
                        )) {
                          await archive.clear();
                          await archive.sync();
                        }
                      }),
                child: const Text('清空日记'),
              ),
            ],
          ),
          if (busy || archive.syncing) const LinearProgressIndicator(),
          if (notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(notice),
            ),
          const SizedBox(height: 20),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Text(
                '还没有日记。结束一次聊天，八千代会把这段相处写进日记。',
                style: TextStyle(height: 1.8),
              ),
            )
          else ...[
            DropdownButtonFormField<String>(
              key: ValueKey(entry?['diaryId']),
              initialValue: '${entry?['diaryId']}',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择日记'),
              items: entries.reversed
                  .map(
                    (v) => DropdownMenuItem(
                      value: '${v['diaryId']}',
                      child: Text(
                        '${v['date'] ?? ''} ${v['time'] ?? ''} · ${v['characterName'] ?? ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) => setState(() => selected = id),
            ),
            const SizedBox(height: 20),
            SiteCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '${entry?['content'] ?? ''}',
                    style: const TextStyle(fontSize: 14, height: 2),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                            if (await roomConfirm(
                              context,
                              '删除这篇日记？',
                              '删除会同步到网站，无法恢复。',
                            )) {
                              await archive.delete('${entry!['diaryId']}');
                              await archive.sync();
                            }
                          }),
                    child: const Text('删除这篇日记'),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}
