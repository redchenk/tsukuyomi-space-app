import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/llm_client.dart';
import '../../core/models.dart';
import '../../core/room_reference.dart';
import '../room/room_controller.dart';
import '../site/native_site_shell.dart';
import '../site/site_widgets.dart';
import 'gomoku.dart';

int? _choose(String saved) => Gomoku.restore(saved)?.choose();

class GomokuPage extends StatefulWidget {
  const GomokuPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<GomokuPage> createState() => _GomokuPageState();
}

class _GomokuPageState extends State<GomokuPage> {
  Gomoku game = Gomoku();
  final text = TextEditingController(), companion = LlmClient();
  final history = <ChatTurn>[];
  String reply = '', error = '', _identity = '';
  bool thinking = false, chatting = false, loaded = false;
  int revision = 0, chatRevision = 0;
  int? hint;
  Future<void> writes = Future.value();
  RoomController get c => widget.controller;
  String get identity => '${c.scope}:${c.settings.toJson()}';
  @override
  void initState() {
    super.initState();
    _identity = identity;
    c.addListener(_changed);
    _restore();
  }

  void _changed() {
    if (_identity == identity) return;
    _identity = identity;
    companion.cancel();
    chatRevision++;
    history.clear();
    if (mounted) {
      setState(() {
        reply = '';
        error = '';
        chatting = false;
      });
    }
  }

  Future<void> _restore() async {
    final saved = await c.storage.draft('gomoku:v1');
    if (!mounted) return;
    setState(() {
      game = Gomoku.restore(saved) ?? Gomoku();
      loaded = true;
    });
    _replyMove();
  }

  void _save() {
    final saved = game.save();
    writes = writes
        .catchError((_) {})
        .then((_) => c.storage.saveDraft('gomoku:v1', saved));
  }

  Future<void> _replyMove() async {
    if (game.turn == game.human || game.winner != 0 || game.draw) return;
    final epoch = ++revision;
    setState(() => thinking = true);
    final move = await compute(_choose, game.save());
    if (!mounted || epoch != revision) return;
    setState(() {
      if (move != null) game.play(move);
      thinking = false;
    });
    _save();
  }

  void _play(int index) {
    if (!loaded || thinking || game.turn != game.human || !game.play(index)) {
      return;
    }
    setState(() => hint = null);
    _save();
    _replyMove();
  }

  void _new({int? human, String? difficulty}) {
    revision++;
    companion.cancel();
    chatRevision++;
    history.clear();
    setState(() {
      game = Gomoku(
        human: human ?? game.human,
        difficulty: difficulty ?? game.difficulty,
      );
      hint = null;
      thinking = false;
      chatting = false;
      reply = '';
    });
    _save();
    _replyMove();
  }

  Future<void> _hint() async {
    if (thinking || game.winner != 0 || game.draw) return;
    final epoch = revision, saved = game.save();
    final move = await compute(_choose, saved);
    if (mounted && epoch == revision && saved == game.save()) {
      setState(() => hint = move);
    }
  }

  Future<void> _chat() async {
    final question = text.text.trim();
    if (question.isEmpty || chatting) return;
    if (c.settings.demo || c.settings.model.isEmpty) {
      widget.onGo('/room/settings');
      return;
    }
    final epoch = ++chatRevision, owner = identity;
    setState(() {
      chatting = true;
      reply = '';
      error = '';
    });
    final message = jsonEncode({
      'event': 'chat',
      'board': game.context(hint: hint),
      'userText': question,
    });
    companion.siteCookie = c.site.cookie;
    companion.siteAccountId = c.account?.id;
    companion.maxReplyChars = 2400;
    companion.systemOverride =
        '${RoomReference.data['chatPersona']}\n【月下五子棋】你坐在用户对面陪他下棋。每轮输入 JSON 的 board 是实际盘面，userText 才是用户的话。落子和胜负由程序确定，不声称改变棋局，不编造落点。简短自然回应，一至三句，不输出思考、动作或 JSON。';
    try {
      await for (final delta in companion.reply(c.settings, history, message)) {
        if (!mounted || epoch != chatRevision || owner != identity) return;
        setState(() => reply += delta);
      }
      if (!mounted || epoch != chatRevision || owner != identity) return;
      history.add(
        ChatTurn(
          id: newTurnId(),
          user: message,
          assistant: reply,
          createdAt: DateTime.now(),
        ),
      );
      if (history.length > 8) history.removeAt(0);
      text.clear();
    } catch (e) {
      if (mounted && epoch == chatRevision) {
        setState(() => error = e is ApiFailure ? e.message : '对话暂时不可用，棋局仍可继续');
      }
    } finally {
      if (mounted && epoch == chatRevision) setState(() => chatting = false);
    }
  }

  @override
  void dispose() {
    revision++;
    chatRevision++;
    c.removeListener(_changed);
    companion.cancel();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NativeSiteShell(
    controller: c,
    title: '月下五子棋',
    onGo: widget.onGo,
    onTheme: widget.onTheme,
    maxWidth: 1000,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const SiteText('月下五子棋', style: TextStyle(fontSize: 28)),
            DropdownButton<int>(
              value: game.human,
              items: const [
                DropdownMenuItem(value: 1, child: SiteText('执黑先手')),
                DropdownMenuItem(value: 2, child: SiteText('执白后手')),
              ],
              onChanged: (v) => _new(human: v),
            ),
            DropdownButton<String>(
              value: game.difficulty,
              items: const [
                DropdownMenuItem(value: 'casual', child: SiteText('轻松')),
                DropdownMenuItem(value: 'challenge', child: SiteText('挑战')),
              ],
              onChanged: (v) => _new(difficulty: v),
            ),
            TextButton(onPressed: _new, child: const SiteText('新的一局')),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            !loaded
                ? '正在恢复棋局…'
                : game.winner != 0
                ? game.winner == game.human
                      ? '你赢了！'
                      : '八千代赢了，再来一局吧。'
                : game.draw
                ? '平局'
                : thinking
                ? '八千代正在落子…'
                : '轮到你了 · 连成五子获胜',
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xffe9d7b6),
                  borderRadius: BorderRadius.circular(18),
                ),
                padding: const EdgeInsets.all(8),
                child: GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 225,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 15,
                  ),
                  itemBuilder: (context, index) => Semantics(
                    label:
                        '${Gomoku.coordinate(index)} ${game.board[index] == 1
                            ? '黑棋'
                            : game.board[index] == 2
                            ? '白棋'
                            : '空位'}',
                    button: game.board[index] == 0,
                    child: GestureDetector(
                      key: ValueKey('gomoku-$index'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _play(index),
                      child: CustomPaint(
                        painter: _Stone(
                          game.board[index],
                          hint == index,
                          game.line.contains(index),
                          game.moves.lastOrNull == index,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Wrap(
          spacing: 10,
          children: [
            TextButton.icon(
              onPressed: !loaded
                  ? null
                  : () {
                      revision++;
                      game.undo();
                      setState(() {
                        thinking = false;
                        hint = null;
                      });
                      _save();
                    },
              icon: const Icon(Icons.undo),
              label: const SiteText('悔棋'),
            ),
            TextButton.icon(
              onPressed: thinking ? null : _hint,
              icon: const Icon(Icons.lightbulb_outline),
              label: const SiteText('提示'),
            ),
            TextButton(
              onPressed: () => widget.onGo('/game'),
              child: const SiteText('游戏中心'),
            ),
          ],
        ),
        SiteCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SiteText('和八千代聊棋'),
              const SizedBox(height: 8),
              if (reply.isNotEmpty) SelectableText(reply),
              if (error.isNotEmpty) Text(error),
              TextField(
                controller: text,
                maxLength: 500,
                decoration: const InputDecoration(hintText: '问问这一步，或聊点别的…'),
                onSubmitted: (_) => _chat(),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: chatting ? null : _chat,
                    child: const SiteText('发送'),
                  ),
                  if (chatting)
                    TextButton(
                      onPressed: () {
                        companion.cancel();
                        chatRevision++;
                        setState(() => chatting = false);
                      },
                      child: const SiteText('停止'),
                    ),
                ],
              ),
              const SiteText(
                '聊天使用房间当前模型，按所选服务计费。棋局可离线游玩。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Stone extends CustomPainter {
  _Stone(this.stone, this.hint, this.won, this.last);
  final int stone;
  final bool hint, won, last;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero),
        paint = Paint()
          ..color = const Color(0xff917b56)
          ..strokeWidth = .6;
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      paint,
    );
    if (stone != 0) {
      paint.color = stone == 1 ? const Color(0xff252737) : Colors.white;
      canvas.drawCircle(center, size.shortestSide * .42, paint);
    }
    if (hint || won || last) {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = won ? const Color(0xff36785c) : const Color(0xffac4d6d);
      canvas.drawCircle(
        center,
        size.shortestSide * (stone == 0 ? .2 : .27),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Stone old) =>
      old.stone != stone ||
      old.hint != hint ||
      old.won != won ||
      old.last != last;
}
