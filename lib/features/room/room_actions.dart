import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../../core/room_files.dart';
import 'room_controller.dart';
import 'room_style.dart';

Future<void> editRoomTurn(
  BuildContext context,
  RoomController c,
  ChatTurn turn,
) async {
  final field = TextEditingController(text: turn.user), scope = c.scope;
  try {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑最后一条消息'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: field,
            maxLines: 8,
            minLines: 3,
            maxLength: 12000,
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: const Text('保存并重新生成'),
          ),
        ],
      ),
    );
    if (value != null && value.isNotEmpty && scope == c.scope) {
      await c.send(value, replacement: turn);
    }
  } finally {
    field.dispose();
  }
}

Future<void> endRoomConversation(
  BuildContext context,
  RoomController c,
  VoidCallback onDiary,
) async {
  if (c.generating || !c.canSend) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _EndConversation(controller: c, onDiary: onDiary),
  );
}

class _EndConversation extends StatefulWidget {
  const _EndConversation({required this.controller, required this.onDiary});
  final RoomController controller;
  final VoidCallback onDiary;
  @override
  State<_EndConversation> createState() => _EndConversationState();
}

class _EndConversationState extends State<_EndConversation> {
  bool working = false;
  String error = '';
  Future<void> finish(bool skip) async {
    setState(() {
      working = true;
      error = '';
    });
    try {
      await widget.controller.finishDiary(withoutDiary: skip);
      if (mounted) {
        Navigator.pop(context);
        if (!skip) widget.onDiary();
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '生成失败，对话已保留，请重试');
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !working,
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => AlertDialog(
        title: const Text('把这段聊天写成日记？'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  working
                      ? widget.controller.diaryStatus
                      : '结束后会清空当前聊天，记忆和已经保存的日记会保留。',
                ),
                if (working) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(widget.controller.diaryText),
                ],
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: working
            ? [
                TextButton(
                  onPressed: widget.controller.cancelDiary,
                  child: const Text('停止生成并保留对话'),
                ),
              ]
            : [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('继续聊天'),
                ),
                TextButton(
                  onPressed: () => finish(true),
                  child: const Text('不生成日记，直接结束'),
                ),
                FilledButton(
                  onPressed: () => finish(false),
                  child: Text(error.isEmpty ? '生成日记并结束' : '重试保存日记'),
                ),
              ],
      ),
    ),
  );
}

Future<void> shareRoomTurn(
  BuildContext context,
  RoomController c,
  ChatTurn turn,
) => showDialog<void>(
  context: context,
  builder: (context) => _RoomShare(controller: c, turn: turn),
);

class _RoomShare extends StatefulWidget {
  const _RoomShare({required this.controller, required this.turn});
  final RoomController controller;
  final ChatTurn turn;
  @override
  State<_RoomShare> createState() => _RoomShareState();
}

class _RoomShareState extends State<_RoomShare> {
  final card = GlobalKey();
  final title = TextEditingController(text: '与八千代的一次对话');
  String error = '', link = '', shareKey = '';
  bool busy = false;
  late final owner = widget.controller.scope;
  String get cacheKey => '$owner.share.${widget.turn.id}';
  @override
  void initState() {
    super.initState();
    _restoreShare();
  }

  Future<void> _restoreShare() async {
    try {
      final raw = await widget.controller.storage.draft(cacheKey);
      if (raw.isEmpty || !mounted || owner != widget.controller.scope) return;
      final saved = jsonMap(jsonDecode(raw));
      setState(() {
        shareKey = '${saved['shareKey'] ?? ''}';
        link = '${saved['link'] ?? ''}';
        title.text = '${saved['title'] ?? '与八千代的一次对话'}';
      });
    } catch (_) {
      if (mounted) setState(() => error = '上次分享记录读取失败，可重新创建链接');
    }
  }

  Future<void> _saveShare() => widget.controller.storage.saveDraft(
    cacheKey,
    jsonEncode({
      'shareKey': shareKey,
      'link': link,
      'title': title.text.trim(),
    }),
  );

  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<Uint8List> bytes() async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        card.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      if (owner != widget.controller.scope) {
        throw const ApiFailure('账号已切换，请重新打开分享');
      }
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is ApiFailure ? e.message : '分享失败，请重试');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> publish() async {
    final c = widget.controller;
    if (title.text.trim().isEmpty) throw const ApiFailure('请填写分享标题');
    if (!c.workspace.online) throw const ApiFailure('请登录并联网后创建分享链接');
    await c.sync();
    if (c.turns.any((v) => v.id == widget.turn.id && v.pending)) {
      throw const ApiFailure('请先完成对话同步');
    }
    final data = await bytes();
    final asset = jsonMap(
      (await c.workspace.request('POST', '/api/assets', {
        'dataUrl': 'data:image/png;base64,${base64Encode(data)}',
        'fileName': 'room-${widget.turn.id}.png',
        'mimeType': 'image/png',
        'alt': title.text.trim(),
        'storage': 'auto',
        'collection': 'share-card',
      }))['data'],
    );
    if (owner != c.scope) throw const ApiFailure('账号已切换');
    final share = jsonMap(
      (await c.workspace.request('POST', '/api/room/shares', {
        'turnId': widget.turn.id,
        'title': title.text.trim(),
        'ogImageAssetId': asset['id'],
        'scene': c.workspace.world,
      }))['data'],
    );
    if (owner != c.scope) throw const ApiFailure('账号已切换');
    if (mounted) {
      setState(() {
        shareKey = '${share['shareKey']}';
        link = endpointUri(c.settings.siteUrl)
            .resolve('${share['path']}')
            .toString();
      });
      await _saveShare();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('分享这段相遇', style: TextStyle(fontSize: 22)),
                    ),
                    IconButton(
                      tooltip: '关闭分享',
                      onPressed: busy ? null : () => Navigator.pop(context),
                      icon: const Icon(CupertinoIcons.xmark),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: title,
                  enabled: !busy && link.isEmpty,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: '分享标题'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                RepaintBoundary(
                  key: card,
                  child: Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xfff2edf9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        color: Color(0xff393047),
                        fontSize: 14,
                        height: 1.7,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const CharacterAvatar(size: 48, radius: 14),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(
                                  '月读空间\n${title.text.trim()}',
                                  style: const TextStyle(fontSize: 16),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Text(
                            '你：${widget.turn.user}',
                            maxLines: 8,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            '八千代：${widget.turn.assistant}',
                            maxLines: 18,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            '${widget.turn.createdAt.toLocal().toString().substring(0, 16)} · TSUKUYOMI SPACE',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xff766987),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (link.isNotEmpty) SelectableText(link),
                if (error.isNotEmpty)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (busy) const LinearProgressIndicator(),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              final data = await bytes();
                              if (!context.mounted) return;
                              await exportRoomFile(
                                context,
                                data,
                                'tsukuyomi-${widget.turn.id}.png',
                                'image/png',
                              );
                            }),
                      child: const Text('保存图片'),
                    ),
                    if (link.isEmpty)
                      FilledButton(
                        onPressed: busy ? null : () => run(publish),
                        child: const Text('创建公开分享链接'),
                      ),
                    if (link.isNotEmpty) ...[
                      FilledButton(
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: link)),
                        child: const Text('复制链接'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                await widget.controller.workspace.request(
                                  'DELETE',
                                  '/api/room/shares/${Uri.encodeComponent(shareKey)}',
                                );
                                if (mounted) {
                                  setState(() {
                                    link = '';
                                    shareKey = '';
                                  });
                                  await _saveShare();
                                }
                              }),
                        child: const Text('撤销链接'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  '创建链接后，持有链接的人可以查看这一轮对话。',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
