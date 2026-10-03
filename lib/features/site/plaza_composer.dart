import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../room/room_style.dart';
import '../../core/site_localization.dart';
import 'plaza_copy.dart';
import 'site_widgets.dart';

class PlazaComposer extends StatefulWidget {
  const PlazaComposer({
    super.key,
    required this.controller,
    required this.signedIn,
    required this.busy,
    required this.onSubmit,
    required this.onLogin,
    required this.onChanged,
    this.author = '',
    this.avatar = '',
    this.site = '',
  });
  final String author, avatar, site;
  final TextEditingController controller;
  final bool signedIn, busy;
  final VoidCallback onSubmit, onLogin;
  final ValueChanged<String> onChanged;

  @override
  State<PlazaComposer> createState() => _PlazaComposerState();
}

class _PlazaComposerState extends State<PlazaComposer> {
  final _inputFocus = FocusNode();
  TextEditingController get controller => widget.controller;
  bool get busy => widget.busy;
  bool get signedIn => widget.signedIn;
  VoidCallback get onSubmit => widget.onSubmit;
  VoidCallback get onLogin => widget.onLogin;
  ValueChanged<String> get onChanged => widget.onChanged;
  bool get _canSubmit =>
      !busy &&
      controller.text.trim().isNotEmpty &&
      controller.text.length <= 300 &&
      controller.value.composing.isCollapsed;

  @override
  void dispose() {
    _inputFocus.dispose();
    super.dispose();
  }

  void _insert(
    String value, {
    bool prefix = false,
    int select = 0,
    int suffix = 0,
  }) {
    if (busy) return;
    final text = controller.text;
    final selection = controller.selection;
    final start = prefix
        ? 0
        : selection.isValid
        ? selection.start
        : text.length;
    final end = prefix
        ? 0
        : selection.isValid
        ? selection.end
        : text.length;
    if (text.length - (end - start) + value.length > 300) return;
    controller.value = TextEditingValue(
      text: text.replaceRange(start, end, value),
      selection: TextSelection(
        baseOffset: start + value.length - suffix - select,
        extentOffset: start + value.length - suffix,
      ),
    );
    onChanged(controller.text);
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    if (!signedIn) {
      return SiteCard(
        child: LayoutBuilder(
          builder: (context, box) {
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plazaCopy(context, '登录，加入这场对话'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  plazaCopy(context, '可以自由浏览，登录后即可发布、回复和点赞。'),
                  style: TextStyle(color: p.muted, height: 1.6),
                ),
              ],
            );
            final login = FilledButton(
              onPressed: onLogin,
              child: const SiteText('去登录'),
            );
            return box.maxWidth < 500
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      text,
                      const SizedBox(height: 12),
                      Align(alignment: Alignment.centerLeft, child: login),
                    ],
                  )
                : Row(
                    children: [
                      Icon(Icons.chat_bubble_outline, color: p.accent),
                      const SizedBox(width: 18),
                      Expanded(child: text),
                      const SizedBox(width: 16),
                      login,
                    ],
                  );
          },
        ),
      );
    }
    return SiteCard(
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final canSubmit =
              !busy &&
              value.text.trim().isNotEmpty &&
              value.text.length <= 300 &&
              value.composing.isCollapsed;
          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (_canSubmit) onSubmit();
              },
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
                if (_canSubmit) onSubmit();
              },
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (widget.author.isNotEmpty) ...[
                      SiteAvatar(
                        value: widget.avatar,
                        name: widget.author,
                        site: widget.site,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            plazaCopy(context, '今天有什么想分享的？'),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${widget.author.isEmpty ? '' : '${widget.author} · '}${plazaCopy(context, '问候、反馈、灵感，都可以留在这里。')}',
                            style: TextStyle(color: p.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('plaza-composer-input'),
                  controller: controller,
                  focusNode: _inputFocus,
                  enabled: !busy,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 300,
                  maxLengthEnforcement:
                      MaxLengthEnforcement.truncateAfterCompositionEnds,
                  onChanged: onChanged,
                  decoration: InputDecoration(
                    hintText: plazaCopy(context, '今天有什么想分享的？'),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mood in const ['问候', '反馈', '灵感'])
                      ActionChip(
                        label: Text(plazaCopy(context, mood)),
                        onPressed: busy
                            ? null
                            : () => _insert(
                                '【${plazaCopy(context, mood)}】 ',
                                prefix: true,
                              ),
                      ),
                    ActionChip(
                      key: const Key('plaza-insert-topic'),
                      avatar: const Icon(Icons.tag, size: 16),
                      label: Text(plazaCopy(context, '话题')),
                      onPressed: busy
                          ? null
                          : () {
                              final topic = plazaCopy(context, '话题');
                              _insert(
                                '#$topic#',
                                select: topic.length,
                                suffix: 1,
                              );
                            },
                    ),
                    ActionChip(
                      key: const Key('plaza-insert-mention'),
                      avatar: const Icon(Icons.alternate_email, size: 16),
                      label: Text(plazaCopy(context, '提及')),
                      onPressed: busy ? null : () => _insert('@'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 12,
                  children: [
                    Text(
                      plazaCopy(context, '用 #话题# 或 @用户名，找到同频的朋友。'),
                      style: TextStyle(fontSize: 11, color: p.muted),
                    ),
                    FilledButton.icon(
                      key: const Key('plaza-submit'),
                      onPressed: canSubmit ? onSubmit : null,
                      icon: const Icon(Icons.send_outlined, size: 16),
                      label: Text(siteTranslate(context, busy ? '提交中…' : '发布')),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
