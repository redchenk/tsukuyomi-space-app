import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/site_localization.dart';
import '../../core/agent/agent_types.dart';
import '../site/site_widgets.dart';
import 'desktop_agent_controller.dart';

class AgentPanel extends StatefulWidget {
  const AgentPanel({super.key, required this.controller, required this.onGo});
  final DesktopAgentController controller;
  final ValueChanged<String> onGo;
  @override
  State<AgentPanel> createState() => _AgentPanelState();
}

class _AgentPanelState extends State<AgentPanel> {
  final _input = TextEditingController(), _scroll = ScrollController();
  DesktopAgentController get c => widget.controller;
  bool _following = true, _unseen = false, _followScheduled = false;
  @override
  void initState() {
    super.initState();
    c.addListener(_follow);
  }

  void _follow() {
    if (!_following) {
      if (!_unseen && mounted) setState(() => _unseen = true);
      return;
    }
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (mounted && _following && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  List<AgentEvent> _timeline() {
    final events = c.session?.events ?? const <AgentEvent>[];
    final results = {
      for (final e in events)
        if (e.type == 'toolResult' && e.id.isNotEmpty) e.id: e,
    };
    final starts = {
      for (final e in events)
        if (e.type == 'toolStart' && e.id.isNotEmpty) e.id,
    };
    return [
      for (final e in events)
        if (e.data['discarded'] != true &&
            e.text.isNotEmpty &&
            e.type != 'done' &&
            !(e.type == 'toolResult' &&
                e.id.isNotEmpty &&
                starts.contains(e.id)))
          if (e.type == 'toolStart' && results.containsKey(e.id))
            AgentEvent(
              'toolResult',
              e.text,
              id: e.id,
              data: {...e.data, ...results[e.id]!.data},
            )
          else
            e,
    ];
  }

  @override
  void dispose() {
    c.removeListener(_follow);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _directory() async {
    final path = await getDirectoryPath(
      confirmButtonText: siteTranslate(context, '选择工作目录'),
    );
    if (path != null) await c.selectWorkspace(path);
  }

  void _send() {
    if (c.busy || _input.text.trim().isEmpty) return;
    final text = _input.text;
    _input.clear();
    c.send(text);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final events = _timeline();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: c.busy ? null : _directory,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const SiteText('选择工作目录'),
              ),
              SizedBox(
                width: 250,
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: c.engine,
                  onChanged: c.busy
                      ? null
                      : (value) async {
                          await c.newSession();
                          c.engine = value!;
                          setState(() {});
                        },
                  items: const [
                    DropdownMenuItem(
                      value: 'auto',
                      child: SiteText(
                        '自动模式',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'structured',
                      child: SiteText(
                        '结构化兼容模式',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: c.busy || c.workspace.isEmpty ? null : c.newSession,
                icon: const Icon(Icons.add_comment_outlined),
                tooltip: siteTranslate(context, '新建会话'),
              ),
            ],
          ),
          if (c.workspace.isNotEmpty)
            Text(
              c.workspace,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (c.status.isNotEmpty)
            SiteText(
              c.status == 'OpenCode' ? '原生工具模式' : c.status,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (c.busy && c.activity.isNotEmpty)
            _AgentActivity(
              text: c.activity,
              started: c.activityAt ?? DateTime.now(),
            ),
          Expanded(
            child: c.approval == null && events.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_awesome, size: 32),
                          const SizedBox(height: 12),
                          const SiteText(
                            '让 Agent 帮你完成任务',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const SiteText(
                            '选择工作目录后，可以编辑文件、运行命令，或协助创作文章。',
                            textAlign: TextAlign.center,
                          ),
                          TextButton(
                            onPressed: () => widget.onGo('/editor'),
                            child: const SiteText('打开文章编辑器'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      NotificationListener<UserScrollNotification>(
                        onNotification: (notification) {
                          if (_scroll.hasClients) {
                            _following = _scroll.position.extentAfter < 100;
                            if (_following && _unseen) {
                              setState(() => _unseen = false);
                            }
                          }
                          return false;
                        },
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount:
                              events.length + (c.approval == null ? 0 : 1),
                          itemBuilder: (context, index) =>
                              index == events.length
                              ? _approval(c.approval!)
                              : KeyedSubtree(
                                  key: ValueKey(
                                    'agent-event-${events[index].id.isEmpty ? '${events[index].type}-${events[index].at.microsecondsSinceEpoch}' : events[index].id}',
                                  ),
                                  child: _event(events[index]),
                                ),
                        ),
                      ),
                      if (_unseen)
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: FilledButton.tonalIcon(
                            onPressed: () {
                              setState(() {
                                _following = true;
                                _unseen = false;
                              });
                              _follow();
                            },
                            icon: const Icon(Icons.arrow_downward, size: 16),
                            label: const SiteText('查看最新进展'),
                          ),
                        ),
                    ],
                  ),
          ),
          if (c.error.isNotEmpty &&
              !events.any((e) => e.type == 'error' && e.text == c.error))
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                c.error,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('agent-input'),
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  enabled: !c.busy,
                  decoration: InputDecoration(
                    hintText: siteTranslate(context, '描述要完成的任务'),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: c.busy ? c.stop : _send,
                tooltip: siteTranslate(context, c.busy ? '停止' : '发送'),
                icon: Icon(c.busy ? Icons.stop : Icons.arrow_upward),
              ),
            ],
          ),
        ],
      );
    },
  );
  Widget _approval(AgentApproval approval) {
    final data = const JsonEncoder.withIndent('  ').convert(approval.arguments);
    return SiteCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SiteText(
            approval.reason,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Text(approval.tool),
          if (approval.tool == 'attachment_upload' &&
              approval.arguments['mime'].toString().startsWith('image/') &&
              approval.arguments['previewPath'] is String)
            Image.file(
              File(approval.arguments['previewPath'] as String),
              height: 120,
              cacheHeight: 240,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SiteText('图片暂不可用'),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 140),
            child: SingleChildScrollView(child: SelectableText(data)),
          ),
          if (approval.tool == 'article_publish')
            TextButton(
              onPressed: () => widget.onGo(
                '/editor${(approval.arguments['id'] as String? ?? '').isEmpty ? '' : '?id=${Uri.encodeComponent(approval.arguments['id'] as String)}'}',
              ),
              child: const SiteText('预览文章草稿'),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => c.respond(false),
                child: const SiteText('拒绝'),
              ),
              FilledButton(
                onPressed: () => c.respond(true),
                child: const SiteText('允许此次操作'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _event(AgentEvent event) {
    if (event.type == 'diff') {
      return ExpansionTile(
        title: Text(event.text),
        leading: const Icon(Icons.difference_outlined),
        children: [
          if (event.data.containsKey('articleId'))
            TextButton.icon(
              onPressed: c.busy ? null : () => c.undoArticle(event),
              icon: const Icon(Icons.undo),
              label: const SiteText('撤销草稿修改'),
            ),
          for (final key in ['before', 'after'])
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                (key == 'before' ? '− ' : '+ ') +
                    (event.data[key]?.toString() ?? ''),
              ),
            ),
        ],
      );
    }
    if (event.type == 'toolStart' || event.type == 'toolResult') {
      final running = event.type == 'toolStart' && c.busy;
      final failed = event.data['state'] == 'failed';
      final arguments = event.data['arguments'] as Map? ?? {};
      final target =
          '${arguments['path'] ?? arguments['id'] ?? arguments['command'] ?? ''}'
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      final title = siteTranslate(context, switch (event.text) {
        'fs_list' => '查看目录',
        'fs_read' => '读取文件',
        'fs_write' => '修改文件',
        'command' => '运行命令',
        'article_read' => '读取文章草稿',
        'article_patch' => '修改文章草稿',
        'article_publish' => '发布文章',
        'attachment_upload' => '上传附件',
        _ => event.text.startsWith('mcp_') ? '调用 MCP 工具' : '执行站内操作',
      });
      return ExpansionTile(
        key: PageStorageKey('agent-tool-${event.id}'),
        title: Text(
          target.isEmpty
              ? title
              : '$title · ${target.length > 160 ? '${target.substring(0, 160)}…' : target}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        subtitle: SiteText(
          running
              ? '正在执行'
              : failed
              ? '操作失败'
              : event.data['state'] == 'declined'
              ? '操作已拒绝'
              : event.type == 'toolStart'
              ? '操作已停止'
              : '操作完成',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        leading: running
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                failed
                    ? Icons.error_outline
                    : event.type == 'toolStart'
                    ? Icons.stop_circle_outlined
                    : Icons.check_circle_outline,
                size: 18,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(event.data),
            ),
          ),
        ],
      );
    }
    final commentary =
        event.type == 'commentary' || event.data['kind'] == 'commentary';
    if (commentary || event.type == 'info') {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: SelectableText(
          commentary ? event.text : siteTranslate(context, event.text),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: event.type == 'user'
            ? Alignment.centerRight
            : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
          ),
          child: event.type == 'assistant'
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MarkdownBody(
                      data: event.text,
                      selectable: true,
                      styleSheet: MarkdownStyleSheet.fromTheme(
                        Theme.of(context),
                      ),
                      onTapLink: (_, href, _) {
                        final uri = Uri.tryParse(href ?? '');
                        if (uri != null &&
                            ['http', 'https'].contains(uri.scheme)) {
                          unawaited(
                            launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            ),
                          );
                        }
                      },
                    ),
                    if (event.data['interrupted'] == true)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: SiteText('回复已中断'),
                      ),
                  ],
                )
              : SelectableText(
                  ['user', 'assistant'].contains(event.type)
                      ? event.text
                      : siteTranslate(context, event.text),
                ),
        ),
      ),
    );
  }
}

class _AgentActivity extends StatefulWidget {
  const _AgentActivity({required this.text, required this.started});
  final String text;
  final DateTime started;
  @override
  State<_AgentActivity> createState() => _AgentActivityState();
}

class _AgentActivityState extends State<_AgentActivity> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = DateTime.now().difference(widget.started).inSeconds;
    return Padding(
      key: const Key('agent-progress'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: SiteText(
                widget.text,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Text(
            '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}
