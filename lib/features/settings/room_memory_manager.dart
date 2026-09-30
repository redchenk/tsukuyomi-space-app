import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../../core/room_memory_source.dart';
import '../../core/site_localization.dart';
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
  int maxContentLength = 12000,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) => _RecordEditor(
    title: title,
    value: value,
    knowledge: knowledge,
    maxContentLength: maxContentLength,
  ),
);

class _RecordEditor extends StatefulWidget {
  const _RecordEditor({
    required this.title,
    required this.value,
    required this.knowledge,
    required this.maxContentLength,
  });
  final String title;
  final Map<String, dynamic> value;
  final bool knowledge;
  final int maxContentLength;
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
    importance = (v['importance'] as num? ?? .5).toDouble().clamp(0, 1);
    confidence = (v['confidence'] as num? ?? .8).toDouble().clamp(0, 1);
    fields['importance'] = TextEditingController(
      text: importance.toStringAsFixed(2),
    );
    fields['confidence'] = TextEditingController(
      text: confidence.toStringAsFixed(2),
    );
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
            for (final e in fields.entries.where(
              (e) => !['importance', 'confidence'].contains(e.key),
            ))
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
              _score('importance', '重要度', '影响检索优先级'),
              _score('confidence', '置信度', '记忆内容的可靠程度'),
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
          if (content.length > widget.maxContentLength) {
            setState(
              () => error = '内容不能超过 ${widget.maxContentLength} 字，原记录不会被截断',
            );
            return;
          }
          if (!widget.knowledge) {
            try {
              importance = roomMemoryScoreValue(
                double.tryParse(fields['importance']!.text),
                '重要度',
                double.nan,
              );
              confidence = roomMemoryScoreValue(
                double.tryParse(fields['confidence']!.text),
                '置信度',
                double.nan,
              );
              if (!importance.isFinite || !confidence.isFinite) {
                throw const ApiFailure('重要度和置信度请填写 0 到 1 的数值');
              }
            } catch (_) {
              setState(() => error = '重要度和置信度请填写 0 到 1 的数值');
              return;
            }
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

  Widget _score(String key, String label, String hint) {
    final value = key == 'importance' ? importance : confidence;
    void change(double next) {
      if (key == 'importance') {
        importance = next;
      } else {
        confidence = next;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: ValueKey('memory-$key-number'),
          controller: fields[key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: '$label数值', helperText: hint),
          onChanged: (text) {
            final parsed = double.tryParse(text);
            if (parsed != null &&
                parsed.isFinite &&
                parsed >= 0 &&
                parsed <= 1) {
              setState(() => change(parsed));
            }
          },
        ),
        Semantics(
          label: '$label滑块',
          child: Slider(
            key: ValueKey('memory-$key-slider'),
            value: value,
            divisions: 100,
            label: value.toStringAsFixed(2),
            onChanged: (next) => setState(() {
              change(next);
              fields[key]!.text = next.toStringAsFixed(2);
            }),
          ),
        ),
      ],
    );
  }
}

class RoomMemorySourcePanel extends StatelessWidget {
  const RoomMemorySourcePanel({super.key, required this.controller});
  final RoomController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.workspace,
    builder: (context, _) {
      if (controller.account == null) return const SizedBox.shrink();
      final workspace = controller.workspace;
      final busy =
          workspace.memoryChoicePending || workspace.memoryChoiceLoading;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '当前记忆来源：${workspace.usesLocalMemory ? '本地数据' : '云端数据'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => workspace.refreshMemoryChoice(force: true),
                    child: const SiteText('重新选择'),
                  ),
                ],
              ),
              Text(
                workspace.memoryLocationText,
                style: const TextStyle(fontSize: 12),
              ),
              if (workspace.memoryChoiceVisible) ...[
                const Divider(height: 24),
                const SiteText(
                  '登录后，如何使用这台设备的记忆？',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '登录前的访客记忆 ${workspace.guestMemories.length} 条 · 当前账号的本地记忆 ${workspace.localMemories.length} 条 · 云端记忆 ${workspace.cloudMemoryCount ?? '待读取'}',
                ),
                const SizedBox(height: 12),
                for (final option in const [
                  ('local', '使用本地数据', '在此设备使用本地记忆。云端原有记忆保留，新记忆不上传。'),
                  ('merge', '合并本地与云端数据', '将本地记忆导入当前账号，保留云端记忆并去重，其他设备也能使用。'),
                  ('cloud', '使用云端数据', '继续使用账号已有记忆，本地原件保留，不导入。'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () async {
                              try {
                                await workspace.chooseMemorySource(option.$1);
                              } catch (_) {
                                /* Workspace keeps the complete retryable error. */
                              }
                            },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Column(
                          children: [
                            SiteText(
                              option.$2,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            SiteText(
                              option.$3,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SiteText(
                  '选择仅针对当前账号和此设备；清理应用数据会丢失本地记忆。稍后可通过“重新选择”调整。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
              if (busy) const LinearProgressIndicator(),
              if (workspace.memoryChoiceProgress.isNotEmpty)
                Text(workspace.memoryChoiceProgress),
              if (workspace.memoryChoiceError.isNotEmpty) ...[
                Text(
                  workspace.memoryChoiceError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => workspace.refreshMemoryChoice(force: true),
                  child: const SiteText('重新读取'),
                ),
              ],
            ],
          ),
        ),
      );
    },
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
  int memoryRevision = 0;
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic> vector = {};
  Map<String, dynamic>? failedDraft;
  @override
  void initState() {
    super.initState();
    scope = widget.controller.workspace.memoryIdentity;
    memoryRevision = widget.controller.memoryRevision;
    failedDraft = widget.controller.workspace.memoryDraft;
    widget.controller.addListener(_account);
    unawaited(_load());
  }

  void _account() {
    if (scope != widget.controller.workspace.memoryIdentity) {
      scope = widget.controller.workspace.memoryIdentity;
      items = [];
      failedDraft = null;
      unawaited(_load());
    } else if (memoryRevision != widget.controller.memoryRevision) {
      memoryRevision = widget.controller.memoryRevision;
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
    final scope = widget.controller.workspace.memoryIdentity;
    try {
      final detail = item == null
          ? <String, dynamic>{}
          : await widget.controller.workspace.memoryDetail(item);
      if (!mounted) return;
      final result = await showRoomRecordEditor(
        context,
        title: item == null ? '添加记忆' : '编辑记忆',
        value: detail,
        maxContentLength: widget.controller.workspace.memoryContentLimit,
      );
      if (result == null) return;
      if (scope != widget.controller.workspace.memoryIdentity) {
        throw const ApiFailure('账号已切换，请重新编辑');
      }
      failedDraft = result;
      widget.controller.workspace.memoryDraftPending = true;
      widget.controller.workspace.memoryDraft = result;
      await widget.controller.workspace.saveMemory(result);
      failedDraft = null;
      widget.controller.workspace.memoryDraftPending = false;
      widget.controller.workspace.memoryDraft = null;
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
    final scope = widget.controller.workspace.memoryIdentity;
    if (!await roomConfirm(
      context,
      id == null ? '清空全部长期记忆？' : '删除这条记忆？',
      '删除后无法恢复。此操作不会清除聊天记录。',
    )) {
      return;
    }
    try {
      if (scope != widget.controller.workspace.memoryIdentity) {
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
        widget.controller.workspace.memoryLocationText,
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
          if (widget.controller.workspace.cloudMemoryAvailable)
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
      if (failedDraft != null) ...[
        OutlinedButton(
          onPressed: () async {
            try {
              await widget.controller.workspace.saveMemory(failedDraft!);
              failedDraft = null;
              widget.controller.workspace.memoryDraftPending = false;
              widget.controller.workspace.memoryDraft = null;
              await _load();
            } catch (e) {
              if (mounted) setState(() => error = '$e');
            }
          },
          child: const Text('重试保存编辑内容'),
        ),
        TextButton(
          onPressed: () => setState(() {
            failedDraft = null;
            widget.controller.workspace.memoryDraft = null;
            widget.controller.workspace.memoryDraftPending = false;
          }),
          child: const SiteText('取消编辑'),
        ),
      ],
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
