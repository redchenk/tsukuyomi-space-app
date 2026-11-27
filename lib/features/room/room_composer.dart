import 'dart:async';

import 'package:file_selector/file_selector.dart';

import '../../core/models.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/site_localization.dart';
import 'room_controller.dart';
import 'room_style.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

/// The editor owns its focus, composing range and controller for its lifetime.
/// Input notifications update this surface, never the Room transcript/stage.
class RoomComposer extends StatefulWidget {
  const RoomComposer({
    super.key,
    required this.controller,
    required this.mobile,
    required this.onAttach,
    this.onTyping,
  });
  final RoomController controller;
  final bool mobile;
  final VoidCallback onAttach;
  final VoidCallback? onTyping;
  @override
  State<RoomComposer> createState() => RoomComposerState();
}

class RoomComposerState extends State<RoomComposer> {
  final _input = TextEditingController();
  final _editorKey = GlobalKey();
  final _focus = FocusNode();
  late Object _state;
  late String _scope, _draft;
  RoomController get c => widget.controller;

  Object _snapshot() => (
    c.scope,
    c.loading,
    c.busy,
    c.generating,
    c.canSend,
    c.settings.demo,
    c.attachment != null,
    c.files,
    c.inputBusy,
    c.recordingInput,
    c.settings.options,
  );

  @override
  void initState() {
    super.initState();
    _scope = c.scope;
    _draft = c.draft;
    _input.text = c.draft;
    _state = _snapshot();
    c.addListener(_changed);
    _input.addListener(_edited);
  }

  void _edited() => setState(() {});

  void _changed() {
    final next = _snapshot();
    final scopeChanged = _scope != c.scope;
    if (!c.generating &&
        (scopeChanged ||
            _draft != c.draft ||
            (_input.text.isEmpty && c.draft.isNotEmpty)) &&
        _input.text != c.draft) {
      _input.value = TextEditingValue(
        text: c.draft,
        selection: TextSelection.collapsed(offset: c.draft.length),
      );
    }
    _scope = c.scope;
    _draft = c.draft;
    if (_state != next) setState(() => _state = next);
  }

  void fillDraft(String value) {
    _input.text = value;
    _focus.requestFocus();
    unawaited(c.saveComposerDraft(value));
  }

  Future<void> _document({bool ocr = false}) async {
    final scope = c.scope, config = c.settings;
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: ocr ? '图片或文档' : '文档',
            extensions: ocr
                ? ['png', 'jpg', 'jpeg', 'pdf', 'docx']
                : c.deepseekSupported
                ? [
                    'txt',
                    'md',
                    'csv',
                    'json',
                    'pdf',
                    'doc',
                    'docx',
                    'ppt',
                    'pptx',
                  ]
                : ['txt', 'md', 'csv', 'json', 'log'],
            uniformTypeIdentifiers: const ['public.data'],
          ),
        ],
      );
      if (file == null ||
          !mounted ||
          scope != c.scope ||
          !identical(config, c.settings)) {
        return;
      }
      final limit =
          c.deepseekSupported &&
              !c.settings.usesOfficialApi &&
              !c.settings.flag('llmProxy')
          ? 100 * 1024 * 1024
          : 8 * 1024 * 1024;
      if (await file.length() > limit) {
        throw ApiFailure('文件不能超过 ${limit ~/ (1024 * 1024)} MB');
      }
      if (c.deepseekSupported) {
        await c.attachDocument(
          await file.readAsBytes(),
          file.name,
          file.mimeType ?? 'application/octet-stream',
          ocr: ocr,
        );
      } else {
        final text = await file.readAsString();
        if (!mounted || scope != c.scope || !identical(config, c.settings)) {
          return;
        }
        if (text.length + c.draft.length > 12000) {
          throw const ApiFailure('文档文字超过 12000 字，请分段添加');
        }
        fillDraft(
          [
            c.draft,
            '【附件：${file.name}】',
            text,
          ].where((s) => s.isNotEmpty).join('\n\n'),
        );
      }
    } catch (e) {
      if (mounted && scope == c.scope) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiFailure ? e.message : '无法读取此文件')),
        );
      }
    }
  }

  void _send() {
    if ((_input.text.trim().isEmpty &&
            c.attachment == null &&
            c.files.isEmpty) ||
        !c.canSend) {
      return;
    }
    final value = _input.text;
    if (value.trim().length > 12000) {
      unawaited(c.send(value));
      return;
    }
    _input.clear();
    unawaited(c.send(value));
  }

  @override
  void didUpdateWidget(RoomComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _input.removeListener(_edited);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobile = widget.mobile;
    final p = RoomStyle(context);
    final composing = _input.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;
    final input = Shortcuts(
      key: _editorKey,
      shortcuts: {
        if (!mobile && !isComposing)
          const SingleActivator(LogicalKeyboardKey.enter):
              const _SendMessageIntent(),
        if (!isComposing) ...{
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              const _SendMessageIntent(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              const _SendMessageIntent(),
        },
      },
      child: Actions(
        actions: {
          _SendMessageIntent: CallbackAction<_SendMessageIntent>(
            onInvoke: (_) {
              _send();
              return null;
            },
          ),
        },
        child: TextField(
          key: const Key('message-input'),
          onChanged: (value) {
            widget.onTyping?.call();
            unawaited(c.saveComposerDraft(value));
          },
          controller: _input,
          focusNode: _focus,
          enabled: !c.loading && !c.busy,
          readOnly: c.generating,
          minLines: 1,
          maxLines: 4,
          textInputAction: TextInputAction.newline,
          style: TextStyle(
            fontSize: mobile ? 16 : 13,
            height: mobile ? 1.5 : 1.65,
            color: p.ink,
          ),
          decoration: InputDecoration(
            hintText: siteTranslate(
              context,
              mobile && c.settings.demo ? '离线演示 · 和八千代聊聊…' : '和八千代说点什么…',
            ),
            filled: false,
            isDense: true,
            hintStyle: TextStyle(
              fontSize: mobile ? 14 : 12,
              color: p.muted.withValues(alpha: .7),
            ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: mobile ? 5 : 2,
              vertical: mobile ? 10 : 2,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
          ),
        ),
      ),
    );
    final attach = Tooltip(
      message: '添加图片',
      child: IconButton(
        onPressed: c.canSend ? widget.onAttach : null,
        icon: Icon(CupertinoIcons.photo, size: mobile ? 22 : 18),
        style: IconButton.styleFrom(
          disabledForegroundColor: p.muted,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size(mobile ? 44 : 30, mobile ? 44 : 30),
        ),
      ),
    );
    final send = Tooltip(
      message: c.generating ? '停止生成' : '发送',
      child: FilledButton(
        onPressed: c.generating
            ? () => c.stop(fromComposer: true)
            : (!c.canSend ||
                      (_input.text.trim().isEmpty &&
                          c.attachment == null &&
                          c.files.isEmpty)
                  ? null
                  : _send),
        style: FilledButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.primary.withValues(alpha: .5),
          disabledForegroundColor: p.onPrimary,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size(mobile ? 44 : 67, mobile ? 44 : 29),
          padding: EdgeInsets.symmetric(horizontal: mobile ? 0 : 10),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!mobile) ...[
              Text(
                c.generating ? '停止' : '发送',
                style: const TextStyle(fontSize: 10),
              ),
              const SizedBox(width: 6),
            ],
            Icon(
              c.generating
                  ? CupertinoIcons.stop_fill
                  : CupertinoIcons.paperplane,
              size: mobile ? 24 : 16,
            ),
          ],
        ),
      ),
    );
    final compact =
        mobile &&
        MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom <
            300;
    if (compact) {
      return Container(
        key: const Key('room-composer'),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: p.glass,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            PopupMenuButton<String>(
              tooltip: '添加附件与工具',
              icon: const Icon(Icons.add),
              onSelected: (v) {
                if (v == 'image') {
                  widget.onAttach();
                } else if (v == 'file') {
                  _document();
                } else if (v == 'ocr') {
                  _document(ocr: true);
                } else {
                  c.toggleDeepseek(v);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'image', child: SiteText('添加图片')),
                const PopupMenuItem(value: 'file', child: SiteText('添加文件')),
                if (c.deepseekSupported) ...[
                  const PopupMenuItem(
                    value: 'ocr',
                    child: SiteText('提取文字 OCR'),
                  ),
                  for (final option in [
                    ('deepseekThinking', '深度思考'),
                    ('deepseekSearch', '联网搜索'),
                    ('deepseekReadUrl', '阅读链接'),
                  ])
                    CheckedPopupMenuItem(
                      value: option.$1,
                      checked: c.settings.flag(
                        option.$1,
                        option.$1 == 'deepseekReadUrl',
                      ),
                      child: SiteText(option.$2),
                    ),
                ],
              ],
            ),
            Expanded(child: input),
            if (c.deepseekSupported)
              IconButton(
                tooltip: c.recordingInput ? '停止录音并转写' : '语音输入',
                onPressed: c.canSend || c.recordingInput
                    ? c.toggleVoiceInput
                    : null,
                icon: Icon(c.recordingInput ? Icons.stop : Icons.mic_none),
              ),
            send,
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.deepseekSupported)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in [
                  ('deepseekThinking', '深度思考'),
                  ('deepseekSearch', '联网搜索'),
                  ('deepseekReadUrl', '阅读链接'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: SiteText(option.$2),
                      selected: c.settings.flag(
                        option.$1,
                        option.$1 == 'deepseekReadUrl',
                      ),
                      onSelected: c.canSend
                          ? (_) => c.toggleDeepseek(option.$1)
                          : null,
                    ),
                  ),
                IconButton(
                  tooltip: '提取文字 OCR',
                  onPressed: c.canSend ? () => _document(ocr: true) : null,
                  icon: const Icon(Icons.document_scanner_outlined),
                ),
              ],
            ),
          ),
        if (c.files.isNotEmpty)
          Wrap(
            spacing: 6,
            children: [
              for (final file in c.files)
                InputChip(
                  label: Text(
                    '${file['name']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  onDeleted: c.canSend
                      ? () => c.removeFile('${file['id']}')
                      : null,
                ),
            ],
          ),
        if (c.inputBusy || c.recordingInput)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                  child: SiteText(
                    c.recordingInput ? '正在录音 · 最长 120 秒' : '正在处理附件…',
                  ),
                ),
                IconButton(
                  tooltip: '取消',
                  onPressed: () {
                    c.resetInput();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        Container(
          key: const Key('room-composer'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: p.glass,
            border: Border.all(color: p.line),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              input,
              Row(
                children: [
                  attach,
                  IconButton(
                    tooltip: '添加文件',
                    onPressed: c.canSend ? _document : null,
                    icon: const Icon(Icons.attach_file),
                  ),
                  if (c.deepseekSupported)
                    IconButton(
                      tooltip: c.recordingInput ? '停止录音并转写' : '语音输入',
                      onPressed: c.recordingInput || c.canSend
                          ? c.toggleVoiceInput
                          : null,
                      icon: Icon(
                        c.recordingInput
                            ? Icons.stop_circle_outlined
                            : Icons.mic_none,
                      ),
                    ),
                  const Spacer(),
                  send,
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
