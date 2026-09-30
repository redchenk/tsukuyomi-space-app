import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../room/room_controller.dart';
import 'asset_library_page.dart';
import 'content_page_shell.dart';
import 'login_dialog.dart';
import 'native_article_editor.dart';
import 'native_article_document.dart';
import 'native_asset_service.dart';
import 'site_widgets.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.controller,
    required this.path,
    required this.onGo,
    this.onTheme,
    this.editor,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  final NativeArticleEditor? editor;
  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late NativeArticleEditor editor;
  final inputs = {
    for (final key in ['title', 'read_time', 'excerpt', 'content'])
      key: TextEditingController(),
  };
  final bodyFocus = FocusNode();
  String view = 'write';
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    editor =
        widget.editor ?? NativeArticleEditor(widget.controller, widget.path);
    editor.addListener(changed);
    editor.initialize();
  }

  void changed() {
    if (!mounted) return;
    for (final entry in inputs.entries) {
      final value = '${editor.fields[entry.key] ?? ''}';
      if (entry.value.text != value) {
        final selection = entry.value.selection;
        entry.value.value = TextEditingValue(
          text: value,
          selection: selection.isValid
              ? TextSelection(
                  baseOffset: selection.baseOffset.clamp(0, value.length),
                  extentOffset: selection.extentOffset.clamp(0, value.length),
                )
              : TextSelection.collapsed(offset: value.length),
        );
      }
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant EditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path == widget.path) return;
    editor.removeListener(changed);
    if (oldWidget.editor == null) editor.dispose();
    editor =
        widget.editor ?? NativeArticleEditor(widget.controller, widget.path);
    editor.addListener(changed);
    editor.initialize();
  }

  @override
  void dispose() {
    if (editor.dirty) unawaited(editor.saveDraft());
    editor.removeListener(changed);
    if (widget.editor == null) editor.dispose();
    for (final input in inputs.values) {
      input.dispose();
    }
    bodyFocus.dispose();
    super.dispose();
  }

  Future<void> go(String path) async {
    if (leaving) return;
    if (editor.dirty) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const SiteText('离开文章编辑器？'),
          content: const SiteText('未发布的内容会保存到本机草稿。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const SiteText('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const SiteText('保存草稿并离开'),
            ),
          ],
        ),
      );
      if (choice != true || !mounted) return;
      final saved = await editor.saveDraft();
      if (!saved) return;
      if (!mounted) return;
    }
    setState(() => leaving = true);
    widget.onGo(path);
  }

  void insert(
    String value, {
    String before = '',
    String after = '',
    int? selectOffset,
    int? selectLength,
  }) {
    final input = inputs['content']!,
        text = input.text,
        selection = input.selection;
    final start = selection.isValid ? selection.start : text.length,
        end = selection.isValid ? selection.end : text.length;
    final selected = (before.isNotEmpty || after.isNotEmpty) && start != end
        ? text.substring(start, end)
        : value;
    final insertion = '$before$selected$after';
    input.value = TextEditingValue(
      text: text.replaceRange(start, end, insertion),
      selection: selectOffset != null
          ? TextSelection(
              baseOffset: start + selectOffset,
              extentOffset: start + selectOffset + (selectLength ?? 0),
            )
          : before.isNotEmpty || after.isNotEmpty
          ? TextSelection(
              baseOffset: start + before.length,
              extentOffset: start + before.length + selected.length,
            )
          : TextSelection.collapsed(offset: start + insertion.length),
    );
    editor.change('content', input.text);
    setState(() => view = 'write');
    bodyFocus.requestFocus();
  }

  void insertBlock(String prefix, String placeholder) {
    final input = inputs['content']!,
        text = input.text,
        selection = input.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final selected = start == end ? placeholder : text.substring(start, end);
    final leading = start > 0 && !text.substring(0, start).endsWith('\n')
        ? '\n'
        : '';
    final trailing = text.substring(end).startsWith('\n') ? '' : '\n';
    final body = selected.split('\n').map((line) => '$prefix$line').join('\n');
    insert(
      '$leading$body$trailing',
      selectOffset: leading.length + prefix.length,
      selectLength: body.length - prefix.length,
    );
  }

  void insertSnippet(String name) {
    final input = inputs['content']!,
        text = input.text,
        selection = input.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final selected = text.substring(start, end);
    var snippet = nativeMarkdownTemplates[name];
    if (snippet == null) return;
    if (selected.isNotEmpty && name == '代码块') {
      var length = 3;
      for (final match in RegExp(r'`+').allMatches(selected)) {
        if (match.group(0)!.length >= length) {
          length = match.group(0)!.length + 1;
        }
      }
      final fence = '`' * length;
      snippet = '${fence}text\n$selected\n$fence';
    } else if (selected.isNotEmpty && ['提示框', '折叠内容'].contains(name)) {
      snippet = '${snippet.split('\n').first}\n$selected\n:::';
    }
    if (editor.fields['content_format'] == 'html') {
      snippet = parseNativeArticle(snippet, 'markdown').html;
    }
    insert('${start > 0 ? '\n\n' : ''}$snippet\n\n');
  }

  void format(String action) {
    final html = editor.fields['content_format'] == 'html';
    if (!html) {
      final block = {
        'H2': ('## ', '小标题'),
        'H3': ('### ', '小标题'),
        '引用': ('> ', '引用内容'),
        '列表': ('- ', '列表项'),
        '有序列表': ('1. ', '列表项'),
      }[action];
      if (block != null) {
        insertBlock(block.$1, siteTranslate(context, block.$2));
        return;
      }
      final input = inputs['content']!;
      if (action == '代码' &&
          input.selection.isValid &&
          input.selection.textInside(input.text).contains('\n')) {
        insertSnippet('代码块');
        return;
      }
    }
    final wraps = html
        ? {
            '加粗': ('<strong>', '</strong>'),
            '斜体': ('<em>', '</em>'),
            '删除线': ('<del>', '</del>'),
            '高亮': ('<mark>', '</mark>'),
            '代码': ('<code>', '</code>'),
            '链接': ('<a href="https://example.com">', '</a>'),
            'H2': ('<h2>', '</h2>'),
            'H3': ('<h3>', '</h3>'),
            '引用': ('<blockquote>', '</blockquote>'),
            '列表': ('<ul><li>', '</li></ul>'),
            '有序列表': ('<ol><li>', '</li></ol>'),
          }
        : {
            '加粗': ('**', '**'),
            '斜体': ('*', '*'),
            '删除线': ('~~', '~~'),
            '高亮': ('==', '=='),
            '防剧透': (':spoiler[', ']'),
            '代码': ('`', '`'),
            '链接': ('[', '](https://example.com)'),
          };
    final wrap = wraps[action];
    if (wrap != null) insert('内容', before: wrap.$1, after: wrap.$2);
    if (action == '分隔线') insert(html ? '\n<hr>\n' : '\n---\n');
  }

  Future<void> assetPicker({bool cover = false}) async {
    final owner = editor.assets.scope;
    final asset = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (context) => AttachmentsPage(
          controller: widget.controller,
          path: '/attachments',
          onGo: (path) {
            Navigator.pop(context);
            go(path);
          },
          onTheme: widget.onTheme,
          imageOnly: cover,
          onSelect: (asset) => Navigator.pop(context, asset),
        ),
      ),
    );
    if (!mounted || owner != editor.assets.scope || asset == null) return;
    if (cover) {
      editor.change('cover_image', nativeAssetUrl(asset, markdown: true));
      editor.change('cover_image_asset_id', asset['id']);
    } else {
      if (editor.fields['content_format'] == 'html') {
        final url = const HtmlEscape(HtmlEscapeMode.attribute)
            .convert(nativeAssetUrl(asset, markdown: true));
        final name = const HtmlEscape().convert(nativeAssetName(asset));
        insert(
          '${asset['mime_type']}'.startsWith('image/')
              ? '\n<img src="$url" alt="$name">\n'
              : '${asset['mime_type']}'.startsWith('video/')
              ? '\n<video src="$url" controls></video>\n'
              : '${asset['mime_type']}'.startsWith('audio/')
              ? '\n<audio src="$url" controls></audio>\n'
              : '\n<a href="$url">$name</a>\n',
        );
      } else {
        insert('\n${nativeAssetMarkdown(asset)}\n');
      }
    }
  }

  Future<void> embed(bool iframe) async {
    final url = TextEditingController(),
        title = TextEditingController(text: iframe ? '嵌入内容' : '媒体卡片');
    final height = TextEditingController(text: '420');
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: SiteText(iframe ? '嵌入 iframe' : '媒体卡片'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: url,
                decoration: InputDecoration(
                  labelText: siteTranslate(context, 'HTTPS 地址'),
                ),
              ),
              TextField(
                controller: title,
                decoration: InputDecoration(
                  labelText: siteTranslate(context, '标题'),
                ),
              ),
              if (iframe)
                TextField(
                  controller: height,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: siteTranslate(context, '高度（220–900）'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const SiteText('取消'),
          ),
          FilledButton(
            onPressed: () {
              final uri = Uri.tryParse(url.text.trim());
              if (uri == null ||
                  uri.scheme != 'https' ||
                  uri.host.isEmpty ||
                  uri.userInfo.isNotEmpty) {
                return;
              }
              final name = title.text.replaceAll(RegExp(r'[\]\r\n]'), ' '),
                  size = (int.tryParse(height.text) ?? 420).clamp(220, 900);
              Navigator.pop(
                context,
                iframe
                    ? '\n::iframe[$name]($uri "$size")\n'
                    : '\n::media[$name]($uri)\n',
              );
            },
            child: const SiteText('插入'),
          ),
        ],
      ),
    );
    url.dispose();
    title.dispose();
    height.dispose();
    if (value != null && mounted) insert(value);
  }

  Widget input(String key, String label, {int lines = 1, int? maxLength}) =>
      TextField(
        key: ValueKey('editor-$key'),
        controller: inputs[key],
        maxLines: lines,
        maxLength: maxLength,
        enabled: !editor.loading && !editor.submitting,
        focusNode: key == 'content' ? bodyFocus : null,
        onChanged: (value) => editor.change(key, value),
        inputFormatters:
            key == 'content' && editor.fields['content_format'] == 'markdown'
            ? [NativeMarkdownListFormatter()]
            : null,
        decoration: InputDecoration(
          labelText: siteTranslate(context, label),
          alignLabelWithHint: true,
        ),
      );
  Widget _toolbar() => Material(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in {
                'write': '撰写',
                'split': '分栏',
                'preview': '预览',
              }.entries)
                ChoiceChip(
                  label: SiteText(entry.value),
                  selected: view == entry.key,
                  onSelected: (_) => setState(() => view = entry.key),
                ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final action in [
                  'H2',
                  'H3',
                  '加粗',
                  '斜体',
                  '删除线',
                  '高亮',
                  '防剧透',
                  '引用',
                  '列表',
                  '有序列表',
                  '代码',
                  '链接',
                  '分隔线',
                ])
                  TextButton(
                    onPressed: editor.submitting ? null : () => format(action),
                    child: SiteText(action),
                  ),
                PopupMenuButton<String>(
                  tooltip: siteTranslate(context, '插入内容块'),
                  onSelected: insertSnippet,
                  itemBuilder: (_) => [
                    for (final name in nativeMarkdownTemplates.keys)
                      PopupMenuItem(value: name, child: SiteText(name)),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: SiteText('内容块'),
                  ),
                ),
                TextButton(
                  onPressed: () => embed(false),
                  child: const SiteText('媒体卡片'),
                ),
                TextButton(
                  onPressed: () => embed(true),
                  child: const Text('iframe'),
                ),
                FilledButton.tonal(
                  onPressed: () => assetPicker(),
                  child: const SiteText('上传 / 选择附件'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final writable =
        widget.controller.account != null && !widget.controller.sessionExpired;
    final source = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            format('加粗'),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            format('加粗'),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            format('斜体'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            format('斜体'),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            format('链接'),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            format('链接'),
        const SingleActivator(
          LogicalKeyboardKey.keyC,
          meta: true,
          shift: true,
        ): () =>
            insertSnippet('代码块'),
        const SingleActivator(
          LogicalKeyboardKey.keyC,
          control: true,
          shift: true,
        ): () =>
            insertSnippet('代码块'),
      },
      child: input('content', '文章正文', lines: 22),
    );
    final preview = SiteCard(
      child: ArticleBody(
        content: '${editor.fields['content']}',
        format: '${editor.fields['content_format']}',
        site: widget.controller.settings.siteUrl,
        onNavigate: go,
      ),
    );
    final cover = '${editor.fields['cover_image'] ?? ''}';
    return PopScope(
      canPop: leaving || !editor.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) go('/stage');
      },
      child: ContentPageShell(
        controller: widget.controller,
        title: editor.id.isEmpty ? '创作文章' : '编辑文章',
        onGo: go,
        onTheme: widget.onTheme,
        loading: editor.loading,
        error: editor.error,
        notice: editor.notice,
        onRefresh: editor.initialize,
        toolbar: writable && !editor.loading ? _toolbar() : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SiteText(
              editor.id.isEmpty ? '写下新的创作' : '编辑文章',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (!writable)
              SiteCard(
                child: Column(
                  children: [
                    const SiteText('登录后可以创作和编辑自己的文章'),
                    FilledButton(
                      onPressed: () async {
                        await showSiteLogin(context, widget.controller);
                        if (mounted) await editor.initialize();
                      },
                      child: const SiteText('去登录'),
                    ),
                  ],
                ),
              )
            else if (!editor.loading && editor.error.isEmpty ||
                !editor.loading && editor.categories.isNotEmpty) ...[
              input('title', '标题', maxLength: 180),
              const SizedBox(height: 12),
              ExpansionTile(
                key: const Key('article-metadata'),
                title: const SiteText('文章信息'),
                subtitle: const SiteText('分类、封面与摘要'),
                tilePadding: EdgeInsets.zero,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 240,
                        child: DropdownButtonFormField<String>(
                          initialValue:
                              editor.allowedCategories.any(
                                (item) =>
                                    item['name'] == editor.fields['category'],
                              )
                              ? '${editor.fields['category']}'
                              : null,
                          decoration: InputDecoration(
                            labelText: siteTranslate(context, '分类'),
                          ),
                          items: [
                            for (final item in editor.allowedCategories)
                              DropdownMenuItem(
                                value: '${item['name']}',
                                child: Text('${item['name']}'),
                              ),
                          ],
                          onChanged: editor.submitting
                              ? null
                              : (value) => editor.change('category', value),
                        ),
                      ),
                      SizedBox(width: 160, child: input('read_time', '阅读时长')),
                      SizedBox(
                        width: 200,
                        child: DropdownButtonFormField<String>(
                          initialValue: '${editor.fields['content_format']}',
                          decoration: InputDecoration(
                            labelText: siteTranslate(context, '正文格式'),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'markdown',
                              child: Text('Markdown'),
                            ),
                            DropdownMenuItem(
                              value: 'html',
                              child: Text('HTML'),
                            ),
                          ],
                          onChanged: editor.submitting
                              ? null
                              : (value) =>
                                    editor.change('content_format', value),
                        ),
                      ),
                      if (editor.moderator && editor.id.isNotEmpty)
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String>(
                            initialValue: '${editor.fields['status']}',
                            decoration: InputDecoration(
                              labelText: siteTranslate(context, '发布状态'),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'published',
                                child: SiteText('已发布'),
                              ),
                              DropdownMenuItem(
                                value: 'draft',
                                child: SiteText('站点草稿'),
                              ),
                            ],
                            onChanged: editor.submitting
                                ? null
                                : (value) => editor.change('status', value),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SiteText('封面图片'),
                        if (cover.isNotEmpty)
                          SizedBox(
                            height: 180,
                            child: Image.network(
                              endpointUri(widget.controller.settings.siteUrl)
                                  .resolve(cover)
                                  .toString(),
                              fit: BoxFit.contain,
                              headers:
                                  endpointUri(
                                            widget.controller.settings.siteUrl,
                                          ).resolve(cover).origin ==
                                          endpointUri(
                                            widget.controller.settings.siteUrl,
                                          ).origin &&
                                      widget.controller.site.cookie != null
                                  ? {'Cookie': widget.controller.site.cookie!}
                                  : null,
                              errorBuilder: (_, _, _) =>
                                  const SiteText('封面暂时无法预览'),
                            ),
                          ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () => assetPicker(cover: true),
                              child: const SiteText('上传 / 选择封面'),
                            ),
                            if (cover.isNotEmpty)
                              TextButton(
                                onPressed: () {
                                  editor.change('cover_image', null);
                                  editor.change('cover_image_asset_id', null);
                                },
                                child: const SiteText('移除封面'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  input('excerpt', '摘要', lines: 3, maxLength: 200),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: editor.summarizing || editor.submitting
                          ? null
                          : editor.summarize,
                      child: SiteText(editor.summarizing ? '正在生成…' : '自动生成摘要'),
                    ),
                  ),
                  if (editor.summaryMessage.isNotEmpty)
                    SiteText(editor.summaryMessage),
                  const SizedBox(height: 12),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => view == 'preview'
                    ? preview
                    : view == 'split' && constraints.maxWidth >= 760
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: source),
                          const SizedBox(width: 18),
                          Expanded(child: preview),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          source,
                          if (view == 'split') ...[
                            const SizedBox(height: 18),
                            preview,
                          ],
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  siteTr(
                    context,
                    'nativeEditorCharacters',
                    params: {'count': inputs['content']!.text.runes.length},
                  ),
                ),
              ),
              ExpansionTile(
                title: const SiteText('Markdown 语法指南'),
                children: [
                  for (final entry in nativeMarkdownTemplates.entries)
                    ListTile(
                      title: SiteText(entry.key),
                      subtitle: SelectableText(entry.value),
                      trailing: TextButton(
                        onPressed: () => insert('\n\n${entry.value}\n\n'),
                        child: const SiteText('插入示例'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed: editor.submitting || editor.summarizing
                        ? null
                        : () async {
                            final result = await editor.submit();
                            if (mounted && result != null) {
                              setState(() => leaving = true);
                              widget.onGo('/stage');
                            }
                          },
                    child: SiteText(
                      editor.submitting
                          ? '正在保存…'
                          : editor.id.isEmpty
                          ? '发布文章'
                          : '保存更新',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: editor.saveDraft,
                    child: const SiteText('保存本机草稿'),
                  ),
                  TextButton(
                    onPressed: editor.dirty ? editor.discardDraft : null,
                    child: const SiteText('恢复站点内容'),
                  ),
                  TextButton(
                    onPressed: () => go('/stage'),
                    child: const SiteText('取消'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
