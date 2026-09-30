import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

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
  @override
  void initState() {
    super.initState();
    c.addListener(_follow);
  }

  void _follow() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 100) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
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
    builder: (context, _) => Column(
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
            DropdownButton<String>(
              value: c.engine,
              onChanged: c.busy
                  ? null
                  : (value) async {
                      await c.newSession();
                      c.engine = value!;
                      setState(() {});
                    },
              items: const [
                DropdownMenuItem(value: 'auto', child: SiteText('自动模式')),
                DropdownMenuItem(
                  value: 'structured',
                  child: SiteText('结构化兼容模式'),
                ),
              ],
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
          SiteText(c.status, style: Theme.of(context).textTheme.labelSmall),
        Expanded(
          child:
              c.approval == null &&
                  (c.session == null || c.session!.events.isEmpty)
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
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount:
                      (c.session?.events.length ?? 0) +
                      (c.approval == null ? 0 : 1),
                  itemBuilder: (context, index) =>
                      index == (c.session?.events.length ?? 0)
                      ? _approval(c.approval!)
                      : _event(c.session!.events[index]),
                ),
        ),
        if (c.error.isNotEmpty)
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
    ),
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
      return ExpansionTile(
        title: Text(event.text, style: Theme.of(context).textTheme.bodySmall),
        leading: Icon(
          event.type == 'toolStart'
              ? Icons.play_circle_outline
              : Icons.check_circle_outline,
          size: 18,
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
          child: SelectableText(
            ['user', 'assistant'].contains(event.type)
                ? event.text
                : siteTranslate(context, event.text),
          ),
        ),
      ),
    );
  }
}
