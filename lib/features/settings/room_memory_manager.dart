import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../room/room_controller.dart';
import '../site/site_widgets.dart';

Future<bool> roomConfirm(
  BuildContext context,
  String title,
  String detail,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
const memoryTypes = {
  'profile': '用户画像',
  'preference': '偏好规则',
  'project': '项目记忆',
  'episodic': '事件记忆',
  'semantic': '语义记忆',
  'conversation': '对话片段',
};

Future<Map<String, dynamic>?> showRoomRecordEditor(
  BuildContext context, {
  required String title,
  required Map<String, dynamic> value,
  bool knowledge = false,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) =>
      _RecordEditor(title: title, value: value, knowledge: knowledge),
);

class _RecordEditor extends StatefulWidget {
  const _RecordEditor({
    required this.title,
    required this.value,
    required this.knowledge,
  });
  final String title;
  final Map<String, dynamic> value;
  final bool knowledge;
  @override
  State<_RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<_RecordEditor> {
  final fields = <String, TextEditingController>{};
  late String type;
  late double importance, confidence;
  late bool enabled;
  String error = '';
  @override
  void initState() {
    super.initState();
    final v = widget.value;
    for (final key in [
      widget.knowledge ? 'title' : 'summary',
      'content',
      'tags',
    ]) {
      fields[key] = TextEditingController(
        text: v[key] is List ? (v[key] as List).join(', ') : '${v[key] ?? ''}',
      );
    }
    type = '${v['type'] ?? 'semantic'}';
    importance = (v['importance'] as num? ?? .7).toDouble().clamp(0, 1);
    confidence = (v['confidence'] as num? ?? .9).toDouble().clamp(0, 1);
    enabled = v['enabled'] != false;
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.knowledge)
              DropdownButtonFormField<String>(
                initialValue: memoryTypes.containsKey(type) ? type : 'semantic',
                decoration: const InputDecoration(labelText: '类型'),
                items: memoryTypes.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => type = v!),
              ),
            const SizedBox(height: 16),
            for (final e in fields.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TextField(
                  controller: e.value,
                  decoration: InputDecoration(
                    labelText: e.key == 'content'
                        ? '内容'
                        : e.key == 'tags'
                        ? '标签（逗号分隔）'
                        : widget.knowledge
                        ? '标题'
                        : '摘要',
                  ),
                  minLines: e.key == 'content' ? 5 : 1,
                  maxLines: e.key == 'content' ? 12 : 1,
                ),
              ),
            if (widget.knowledge)
              SwitchListTile.adaptive(
                title: const Text('启用这条知识'),
                value: enabled,
                onChanged: (v) => setState(() => enabled = v),
              )
            else ...[
              Text('重要度 ${importance.toStringAsFixed(2)}'),
              Slider(
                value: importance,
                divisions: 20,
                onChanged: (v) => setState(() => importance = v),
              ),
              Text('置信度 ${confidence.toStringAsFixed(2)}'),
              Slider(
                value: confidence,
                divisions: 20,
                onChanged: (v) => setState(() => confidence = v),
              ),
            ],
            if (error.isNotEmpty)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final content = fields['content']!.text.trim(),
              heading = fields[widget.knowledge ? 'title' : 'summary']!.text
                  .trim();
          if (content.isEmpty || heading.isEmpty) {
            setState(() => error = '请填写标题/摘要和内容');
            return;
          }
          if (content.length > 12000) {
            setState(() => error = '内容不能超过 12000 字，原记录不会被截断');
            return;
          }
          Navigator.pop(context, {
            ...widget.value,
            widget.knowledge ? 'title' : 'summary': heading,
            'content': content,
            'tags': widget.knowledge
                ? fields['tags']!.text
                : fields['tags']!.text
                      .split(RegExp('[,，]'))
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList(),
            if (widget.knowledge) 'enabled': enabled,
            if (!widget.knowledge) ...{
              'type': type,
              'importance': importance,
              'confidence': confidence,
            },
          });
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class RoomMemoryManager extends StatefulWidget {
  const RoomMemoryManager({super.key, required this.controller});
  final RoomController controller;
  @override
  State<RoomMemoryManager> createState() => _RoomMemoryManagerState();
}

class _RoomMemoryManagerState extends State<RoomMemoryManager> {
  final query = TextEditingController();
  String type = '', error = '', scope = '';
  bool loading = false, more = false;
  int total = 0, requestId = 0;
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic> vector = {};
  Map<String, dynamic>? failedDraft;
  @override
  void initState() {
    super.initState();
    scope = widget.controller.scope;
    widget.controller.addListener(_account);
    unawaited(_load());
  }

  void _account() {
    if (scope != widget.controller.scope) {
      scope = widget.controller.scope;
      items = [];
      failedDraft = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    requestId++;
    query.dispose();
    widget.controller.removeListener(_account);
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    final id = ++requestId;
    setState(() => loading = true);
    try {
      final result = await widget.controller.workspace.memories(
        query: query.text,
        type: type,
        offset: append ? items.length : 0,
      );
      if (!mounted || id != requestId) return;
      setState(() {
        items = [if (append) ...items, ...jsonRows(result['items'])];
        total = (result['total'] as num? ?? items.length).toInt();
        more = result['hasMore'] == true;
        error = '';
      });
    } catch (e) {
      if (mounted && id == requestId) {
        setState(() => error = e is ApiFailure ? e.message : '记忆读取失败，请重试');
      }
    } finally {
      if (mounted && id == requestId) setState(() => loading = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? item]) async {
    final scope = widget.controller.scope;
    try {
      final detail = item == null
          ? <String, dynamic>{}
          : await widget.controller.workspace.memoryDetail(item);
      if (!mounted) return;
      final result = await showRoomRecordEditor(
        context,
        title: item == null ? '添加记忆' : '编辑记忆',
        value: detail,
      );
      if (result == null) return;
      if (scope != widget.controller.scope) {
        throw const ApiFailure('账号已切换，请重新编辑');
      }
      failedDraft = result;
      await widget.controller.workspace.saveMemory(result);
      failedDraft = null;
      await _load();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is ApiFailure ? e.message : '保存失败，编辑内容已保留，请重试',
        );
      }
    }
  }

  Future<void> _delete(String? id) async {
    final scope = widget.controller.scope;
    if (!await roomConfirm(
      context,
      id == null ? '清空全部长期记忆？' : '删除这条记忆？',
      '删除后无法恢复。此操作不会清除聊天记录。',
    )) {
      return;
    }
    try {
      if (scope != widget.controller.scope) {
        throw const ApiFailure('账号已切换，请重新选择');
      }
      await widget.controller.workspace.deleteMemory(id);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.controller.account == null ? '访客记忆仅保存在此设备。' : '当前账号的私有记忆，与网站同步。',
        style: const TextStyle(fontSize: 12),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: query,
        decoration: InputDecoration(
          labelText: '搜索记忆',
          suffixIcon: IconButton(
            tooltip: '搜索',
            onPressed: loading ? null : () => _load(),
            icon: const Icon(Icons.search),
          ),
        ),
        onSubmitted: (_) => _load(),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: type,
        decoration: const InputDecoration(labelText: '记忆类型'),
        items: [
          const DropdownMenuItem(value: '', child: Text('全部类型')),
          ...memoryTypes.entries.map(
            (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
          ),
        ],
        onChanged: (v) {
          type = v!;
          _load();
        },
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: loading ? null : () => _load(),
            child: const Text('刷新'),
          ),
          FilledButton(
            onPressed: loading ? null : () => _edit(),
            child: const Text('添加记忆'),
          ),
          TextButton(
            onPressed: loading ? null : () => _delete(null),
            child: const Text('清空记忆'),
          ),
          if (widget.controller.workspace.online)
            OutlinedButton(
              onPressed: loading
                  ? null
                  : () async {
                      try {
                        final result = await widget.controller.workspace
                            .request('POST', '/api/room/memory/vector-sync', {
                              'limit': 200,
                              'force': true,
                            });
                        if (mounted) {
                          setState(() => vector = jsonMap(result['data']));
                        }
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      }
                    },
              child: const Text('同步向量记忆'),
            ),
        ],
      ),
      if (vector.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('向量状态：${vector['sync'] ?? vector}'),
        ),
      if (loading) const LinearProgressIndicator(),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (failedDraft != null)
        OutlinedButton(
          onPressed: () async {
            try {
              await widget.controller.workspace.saveMemory(failedDraft!);
              failedDraft = null;
              await _load();
            } catch (e) {
              if (mounted) setState(() => error = '$e');
            }
          },
          child: const Text('重试保存编辑内容'),
        ),
      const SizedBox(height: 16),
      if (!loading && items.isEmpty) const Text('还没有可显示的记忆。'),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SiteCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${memoryTypes[item['type']] ?? item['type']} · 重要度 ${item['importance'] ?? 0} · 置信度 ${item['confidence'] ?? 0}',
                  style: const TextStyle(fontSize: 10),
                ),
                const SizedBox(height: 8),
                Text(
                  '${item['summary'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('展开原文', style: TextStyle(fontSize: 12)),
                  onExpansionChanged: (open) async {
                    if (open) {
                      try {
                        final detail = await widget.controller.workspace
                            .memoryDetail(item);
                        if (mounted) setState(() => item.addAll(detail));
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      }
                    }
                  },
                  children: [SelectableText('${item['content'] ?? '正在读取…'}')],
                ),
                Text(
                  '${item['tags'] is List ? (item['tags'] as List).join(' · ') : item['tags'] ?? ''}',
                  style: const TextStyle(fontSize: 11),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => _edit(item),
                      child: const Text('编辑'),
                    ),
                    TextButton(
                      onPressed: () => _delete('${item['id']}'),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 12),
      Text('已显示 ${items.length} / $total 条记忆'),
      if (more)
        OutlinedButton(
          onPressed: loading ? null : () => _load(append: true),
          child: const Text('加载更多'),
        ),
    ],
  );
}
