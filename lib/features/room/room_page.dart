import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../live2d/character_stage.dart';
import '../settings/settings_dialog.dart';
import 'room_controller.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.controller, this.loadNative = true});
  final RoomController controller;
  final bool loadNative;
  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  final _input = TextEditingController(), _scroll = ScrollController();
  final _focus = FocusNode();
  String _lastScope = '', _lastDraft = '';
  RoomController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_update);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.resume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      c.pause();
    }
  }

  void _update() {
    if (!mounted) return;
    if (_lastScope != c.scope ||
        _lastDraft != c.draft ||
        (!c.generating && _input.text.isEmpty && c.draft.isNotEmpty)) {
      if (!c.generating) {
        _input.text = c.draft;
      }
      _lastScope = c.scope;
      _lastDraft = c.draft;
    }
    final nearBottom =
        !_scroll.hasClients || _scroll.position.extentAfter < 100;
    setState(() {});
    if (nearBottom && (c.turns.isNotEmpty || c.generating)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    if (_input.text.trim().isEmpty || !c.canSend) {
      return;
    }
    final value = _input.text;
    _input.clear();
    unawaited(c.send(value));
  }

  void _settings() => unawaited(showRoomSettings(context, c));
  void _account() => unawaited(showAccountDialog(context, c));
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 960;
          final tight = constraints.maxWidth < 480;
          final date = DateTime.now();
          final stage = CharacterStage(
            voice: c.voice,
            loadNative: widget.loadNative,
          );
          return Row(
            children: [
              if (desktop)
                Container(
                  width: 88,
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: Color(0xff23283b))),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 28),
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xffbca7ed),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.nightlight_round,
                          color: Color(0xff272039),
                        ),
                      ),
                      const SizedBox(height: 52),
                      const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xffcbbaff),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '居所',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xffcbbaff),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '房间设置',
                        onPressed: c.loading ? null : _settings,
                        icon: const Icon(Icons.tune_rounded, size: 22),
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(desktop ? 28 : 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (!desktop) ...[
                            const Icon(
                              Icons.nightlight_round,
                              color: Color(0xffcbbaff),
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                          ],
                          const Text(
                            '月读空间',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2,
                            ),
                          ),
                          if (!tight) ...[
                            const SizedBox(width: 16),
                            const Text(
                              'TSUKUYOMI SPACE',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xff818aa5),
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (!desktop)
                            IconButton(
                              tooltip: '房间设置',
                              onPressed: c.loading ? null : _settings,
                              icon: const Icon(Icons.tune_rounded, size: 20),
                            ),
                          TextButton.icon(
                            onPressed: c.loading || c.generating || c.busy
                                ? null
                                : _account,
                            icon: const Icon(
                              Icons.person_outline_rounded,
                              size: 17,
                            ),
                            label: Text(
                              c.sessionExpired
                                  ? '重新登录'
                                  : c.account?.username ?? '登录',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      if (desktop) ...[
                        const SizedBox(height: 32),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '给日常留一点月光。',
                                    style: TextStyle(
                                      fontSize: 30,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    '一个可以放慢脚步，安心说话的地方。',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Color(0xff929cb7),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${date.month.toString().padLeft(2, '0')} / ${date.day.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xff929cb7),
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 26),
                      ] else
                        const SizedBox(height: 12),
                      Expanded(
                        child: desktop
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(flex: 6, child: stage),
                                  const SizedBox(width: 22),
                                  Expanded(flex: 5, child: _conversation()),
                                ],
                              )
                            : Column(
                                children: [
                                  SizedBox(
                                    height:
                                        MediaQuery.viewInsetsOf(context)
                                                .bottom >
                                            0
                                        ? 116
                                        : (constraints.maxHeight * .34).clamp(
                                            150,
                                            310,
                                          ),
                                    child: stage,
                                  ),
                                  const SizedBox(height: 12),
                                  Expanded(child: _conversation()),
                                ],
                              ),
                      ),
                      if (desktop) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(
                              Icons.lock_outline,
                              size: 12,
                              color: Color(0xff77829d),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              c.settings.demo
                                  ? '离线演示 · 示例回复不会上传'
                                  : '对话直连你配置的模型服务',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xff77829d),
                              ),
                            ),
                            const Spacer(),
                            const Text(
                              'ROOM / 01',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xff77829d),
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
  Widget _conversation() => Container(
    decoration: BoxDecoration(
      color: const Color(0xff161b2c),
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: const Color(0xff282f44)),
    ),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 14, 16),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 18,
                backgroundColor: Color(0xff302b49),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 17,
                  color: Color(0xffdac7ff),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '和八千代说说话',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      c.generating
                          ? '正在听你说，也在认真回应…'
                          : c.settings.demo
                          ? '离线演示 · 在设置中连接模型'
                          : c.syncStatus,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xff8c98b5),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '同步会话',
                onPressed: c.account == null || c.generating
                    ? null
                    : () => unawaited(c.sync()),
                icon: const Icon(Icons.sync_rounded, size: 19),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xff282f44)),
        Expanded(
          child: c.loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (c.turns.isEmpty && !c.generating) _welcome(),
                    for (final turn in c.turns) ...[
                      _bubble(turn.user, user: true),
                      _bubble(
                        turn.assistant,
                        onReplay: () => unawaited(c.replay(turn.assistant)),
                      ),
                      if (turn.pending)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            '已保存在本机 · 等待同步',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xffb6a686),
                            ),
                          ),
                        ),
                    ],
                    if (c.generating) ...[
                      _bubble(c.sendingText, user: true),
                      _bubble(
                        c.partial.isEmpty ? '正在想怎么回答你…' : c.partial,
                        streaming: true,
                      ),
                    ],
                  ],
                ),
        ),
        if (c.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 15,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.error,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                if (c.draft.isNotEmpty && !c.generating)
                  TextButton(
                    onPressed: () => unawaited(c.send(c.draft)),
                    child: const Text('重试'),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Shortcuts(
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.enter, control: true):
                      _SendMessageIntent(),
                  SingleActivator(LogicalKeyboardKey.enter, meta: true):
                      _SendMessageIntent(),
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
                    controller: _input,
                    focusNode: _focus,
                    enabled: !c.loading && !c.busy,
                    readOnly: c.generating,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                    decoration: InputDecoration(
                      hintText: '今天，有什么想告诉我的？',
                      hintStyle: const TextStyle(color: Color(0xff727f9d)),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 15,
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.all(6),
                        child: IconButton.filled(
                          tooltip: c.generating ? '停止生成' : '发送',
                          onPressed: c.loading || c.busy
                              ? null
                              : c.generating
                              ? c.stop
                              : _send,
                          icon: Icon(
                            c.generating
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                            size: 19,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    c.settings.demo
                        ? Icons.science_outlined
                        : Icons.bolt_rounded,
                    size: 12,
                    color: const Color(0xff78859e),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    c.settings.demo ? '演示模式' : c.settings.model,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xff78859e),
                    ),
                  ),
                  const Spacer(),
                  if (c.voice.playing)
                    InkWell(
                      onTap: () => unawaited(c.voice.stop()),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Text('停止语音', style: TextStyle(fontSize: 10)),
                      ),
                    ),
                  const Text(
                    '慢慢来，我在。',
                    style: TextStyle(fontSize: 10, color: Color(0xff78859e)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _welcome() => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '欢迎回来。',
          style: TextStyle(fontSize: 23, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 12),
        const Text(
          '不必准备一个特别的话题。\n今天的开心、小小的烦恼，或者只是打个招呼。',
          style: TextStyle(fontSize: 13, height: 1.9, color: Color(0xffa9b2c8)),
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final text in ['晚上好，八千代', '今天有点累', '想听你讲个故事'])
              ActionChip(
                label: Text(text, style: const TextStyle(fontSize: 11)),
                onPressed: () {
                  _input.text = text;
                  _focus.requestFocus();
                },
              ),
          ],
        ),
      ],
    ),
  );
  Widget _bubble(
    String text, {
    bool user = false,
    bool streaming = false,
    VoidCallback? onReplay,
  }) => Align(
    alignment: user ? Alignment.centerRight : Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: user
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Text(
            user ? '你' : '八千代',
            style: const TextStyle(fontSize: 10, color: Color(0xff8e9ab5)),
          ),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              color: user ? const Color(0xff51416e) : const Color(0xff22283c),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(user ? 16 : 4),
                bottomRight: Radius.circular(user ? 4 : 16),
              ),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.7,
                color: Color(0xffece9f5),
              ),
            ),
          ),
          if (onReplay != null && c.settings.speak && !streaming)
            IconButton(
              tooltip: '朗读',
              onPressed: onReplay,
              icon: const Icon(Icons.volume_up_outlined, size: 15),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    ),
  );
}
