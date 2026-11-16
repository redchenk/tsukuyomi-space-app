import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, RenderSliverList;
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../core/site_localization.dart';
import 'room_actions.dart';
import 'deepseek_details.dart';
import 'room_controller.dart';
import 'room_message_cache.dart';
import 'room_style.dart';
import '../site/native_rich_text.dart';

/// An individual image, question, reply bubble or action row. A long answer is
/// indexed as data rather than mounted as one large Column of SelectableTexts.
enum RoomTranscriptRowKind { image, question, reply, actions, pending }

typedef RoomTranscriptRowId = ({
  String turn,
  RoomTranscriptRowKind kind,
  int part,
});

class RoomTranscriptRow {
  const RoomTranscriptRow(
    this.turn,
    this.kind, {
    this.part = 0,
    this.partCount = 0,
    this.markdown = false,
    this.format = 'markdown',
  });
  final ChatTurn turn;
  final RoomTranscriptRowKind kind;
  final int part, partCount;
  final bool markdown;
  final String format;
  RoomTranscriptRowId get id => (turn: turn.id, kind: kind, part: part);
}

/// A sliver requests row metadata progressively from its visible end. Opening
/// 2,000 turns does not parse or split 2,000 answers before the first frame.
/// Expanded rows retain only turn references and offsets; reply strings remain
/// in RoomMessageCache's bounded LRU instead of an unbounded history index.
class RoomTranscriptRows {
  RoomTranscriptRows(this.owner, {required this.reverse});
  final RoomTranscriptIndex owner;
  final bool reverse;
  List<ChatTurn> _turns = const [];
  final _rows = <RoomTranscriptRow>[];
  final _ends = <int>[0];
  final indices = <RoomTranscriptRowId, int>{};
  int _prepared = 0;
  int get turnCount => _turns.length;
  int get knownRowCount => _rows.length;
  int? get completeRowCount => _prepared == _turns.length ? _rows.length : null;

  void update(List<ChatTurn> turns) {
    var same = 0;
    while (same < _prepared &&
        same < turns.length &&
        identical(_turns[same], turns[same])) {
      same++;
    }
    final keep = _ends[same];
    for (var i = keep; i < _rows.length; i++) {
      indices.remove(_rows[i].id);
    }
    _rows.length = keep;
    _ends.length = same + 1;
    _prepared = same;
    _turns = turns;
  }

  RoomTranscriptRow? rowAt(int index) {
    while (index >= _rows.length && _prepared < _turns.length) {
      final turn = _turns[_prepared++];
      final presentation = owner.presentation(turn);
      owner.preparedTurns++;
      final rows = <RoomTranscriptRow>[
        if (turn.image != null)
          RoomTranscriptRow(turn, RoomTranscriptRowKind.image),
        if (turn.user.isNotEmpty)
          RoomTranscriptRow(turn, RoomTranscriptRowKind.question),
        for (var i = 0; i < presentation.parts.length; i++)
          RoomTranscriptRow(
            turn,
            RoomTranscriptRowKind.reply,
            part: i,
            partCount: presentation.parts.length,
            markdown: presentation.markdown,
            format: presentation.format,
          ),
        RoomTranscriptRow(turn, RoomTranscriptRowKind.actions),
        if (turn.pending)
          RoomTranscriptRow(turn, RoomTranscriptRowKind.pending),
      ];
      for (final row in reverse ? rows.reversed : rows) {
        indices[row.id] = _rows.length;
        _rows.add(row);
      }
      _ends.add(_rows.length);
    }
    return index < _rows.length ? _rows[index] : null;
  }

  void complete() {
    rowAt(0x7fffffff);
  }

  void clear() {
    _turns = const [];
    _rows.clear();
    _ends
      ..clear()
      ..add(0);
    indices.clear();
    _prepared = 0;
  }
}

/// Partitions immutable turn references only when the source changes. Text and
/// widgets are created only as a sliver reaches their rows.
class RoomTranscriptIndex {
  RoomTranscriptIndex(this.cache);
  final RoomMessageCache cache;
  late final history = RoomTranscriptRows(this, reverse: true);
  late final recent = RoomTranscriptRows(this, reverse: false);
  String? _lastSource;
  RoomReplyPresentation? _lastPresentation;
  int updates = 0, preparedTurns = 0;

  RoomReplyPresentation presentation(ChatTurn turn) {
    if (!identical(_lastSource, turn.assistant)) {
      _lastSource = turn.assistant;
      _lastPresentation = cache.reply(turn.assistant);
    }
    return _lastPresentation!;
  }

  void update(List<ChatTurn> turns, bool Function(ChatTurn) historical) {
    updates++;
    final oldTurns = <ChatTurn>[], newTurns = <ChatTurn>[];
    for (final turn in turns) {
      (historical(turn) ? oldTurns : newTurns).add(turn);
    }
    history.update(oldTurns.reversed.toList(growable: false));
    recent.update(newTurns);
  }

  void clear() {
    history.clear();
    recent.clear();
    _lastSource = null;
    _lastPresentation = null;
  }
}

/// Chat owns its subscription and scroll state. Room controls, model animation,
/// composer edits and music cannot rebuild or reindex the transcript.
class RoomChatView extends StatefulWidget {
  const RoomChatView({
    super.key,
    required this.controller,
    required this.mobile,
    required this.onNavigate,
    required this.onNotice,
    this.onScrollActivity,
  });
  final RoomController controller;
  final bool mobile;
  final ValueChanged<String> onNavigate, onNotice;
  final ValueChanged<bool>? onScrollActivity;
  @override
  State<RoomChatView> createState() => RoomChatViewState();
}

class RoomChatViewState extends State<RoomChatView> {
  final _center = GlobalKey();
  final _cache = RoomMessageCache();
  late final _index = RoomTranscriptIndex(_cache);
  late final _scroll = ScrollController(onAttach: _attach, onDetach: _detach);
  final _unread = ValueNotifier(false);
  final _historicalIds = <String>{};
  final _rowWidgets = <RoomTranscriptRowId, (RoomTranscriptRow, Widget)>{};
  DateTime _openedAt = DateTime.now();
  List<ChatTurn>? _source;
  Object? _stamp;
  String _scope = '', _site = '';
  String? _cookie;
  int _builtRows = 0;
  RoomController get c => widget.controller;
  @visibleForTesting
  int get debugBuiltRows => _builtRows;
  @visibleForTesting
  int get debugIndexUpdates => _index.updates;
  @visibleForTesting
  int get debugPreparedTurns => _index.preparedTurns;
  @visibleForTesting
  int get debugCachedReplyCharacters => _cache.cachedReplyCharacters;

  @override
  void initState() {
    super.initState();
    _readSnapshot();
    c.addListener(_changed);
    c.streamRevision.addListener(_follow);
  }

  @override
  void didUpdateWidget(covariant RoomChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.streamRevision.removeListener(_follow);
      _scope = '';
      c.addListener(_changed);
      c.streamRevision.addListener(_follow);
      _readSnapshot();
    }
    if (oldWidget.mobile != widget.mobile ||
        oldWidget.controller != c ||
        oldWidget.onNavigate != widget.onNavigate ||
        oldWidget.onNotice != widget.onNotice) {
      _rowWidgets.clear();
    }
  }

  Object _snapshot(List<ChatTurn> turns) => (
    c.scope,
    turns,
    c.generating,
    c.sendingText,
    c.sharedConversation,
    c.settings.siteUrl,
    c.site.cookie,
  );

  void _readSnapshot() {
    final turns = c.visibleTurns;
    if (_scope != c.scope) {
      _scope = c.scope;
      _cache.clear();
      _index.clear();
      _rowWidgets.clear();
      _openedAt = DateTime.now();
      _historicalIds
        ..clear()
        ..addAll(turns.map((turn) => turn.id));
      _source = null;
      _unread.value = false;
      widget.onScrollActivity?.call(false);
    }
    if (!identical(_source, turns)) {
      _index.update(
        turns,
        (turn) =>
            _historicalIds.contains(turn.id) ||
            !turn.createdAt.isAfter(_openedAt),
      );
      // New replies are usually one turn at a time. Complete their metadata
      // before layout so the growing side always has a finite follow extent.
      _index.recent.complete();
      _source = turns;
    }
    if (_site != c.settings.siteUrl || _cookie != c.site.cookie) {
      _rowWidgets.clear();
      _site = c.settings.siteUrl;
      _cookie = c.site.cookie;
    }
    _stamp = _snapshot(turns);
  }

  void _changed() {
    if (!mounted) return;
    final turns = c.visibleTurns;
    final next = _snapshot(turns);
    if (_stamp == next) return;
    final old = _stamp;
    final changedConversation =
        !identical(_source, turns) ||
        (old
                is (
                  String,
                  List<ChatTurn>,
                  bool,
                  String,
                  Map<String, dynamic>?,
                  String,
                  String?,
                ) &&
            old.$3 != c.generating);
    final atBottom = !_scroll.hasClients || _scroll.position.extentAfter < 100;
    final pixels = _scroll.hasClients ? _scroll.position.pixels : null;
    final changedScope = _scope != c.scope;
    _readSnapshot();
    setState(() {});
    if (changedConversation &&
        !changedScope &&
        !atBottom &&
        (turns.isNotEmpty || c.generating)) {
      _unread.value = true;
    }
    if (changedConversation && atBottom) _scheduleFollow(pixels);
  }

  void _attach(ScrollPosition position) =>
      position.isScrollingNotifier.addListener(_scrolling);
  void _detach(ScrollPosition position) {
    position.isScrollingNotifier.removeListener(_scrolling);
    widget.onScrollActivity?.call(false);
  }

  void _scrolling() => widget.onScrollActivity?.call(
    _scroll.hasClients && _scroll.position.isScrollingNotifier.value,
  );

  void _follow() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 100) {
      _unread.value = true;
      return;
    }
    if (_scroll.position.isScrollingNotifier.value) return;
    _scheduleFollow(_scroll.position.pixels);
  }

  void _scheduleFollow(double? pixels) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _scroll.hasClients &&
          !_scroll.position.isScrollingNotifier.value &&
          (pixels == null || (_scroll.position.pixels - pixels).abs() < 1)) {
        final end = _scroll.position.maxScrollExtent;
        if (end.isFinite) _scroll.jumpTo(end);
      }
    });
  }

  void jumpToLatest() {
    _unread.value = false;
    if (!_scroll.hasClients) return;
    _index.recent.complete();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (end.isFinite) _scroll.jumpTo(end);
    });
  }

  void jumpToStart() {
    if (!_scroll.hasClients) return;
    // The finite extent is deliberately computed only for this explicit jump.
    _index.history.complete();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        final start = _scroll.position.minScrollExtent;
        if (start.isFinite) _scroll.jumpTo(start);
      }
    });
  }

  Widget _row(RoomTranscriptRow row) {
    _builtRows++;
    final found = _rowWidgets.remove(row.id);
    if (found != null && identical(found.$1, row)) {
      _rowWidgets[row.id] = found;
      return found.$2;
    }
    final turn = row.turn;
    final Widget child;
    switch (row.kind) {
      case RoomTranscriptRowKind.image:
        child = Align(
          alignment: Alignment.centerRight,
          child: RoomChatImage(
            controller: c,
            cache: _cache,
            image: turn.image!,
          ),
        );
      case RoomTranscriptRowKind.question:
        child = RoomChatBubble(
          controller: c,
          text: turn.user,
          user: true,
          mobile: widget.mobile,
          time: turn.createdAt,
          onNavigate: widget.onNavigate,
          onNotice: widget.onNotice,
        );
      case RoomTranscriptRowKind.reply:
        child = RoomChatBubble(
          controller: c,
          text: _index.presentation(turn).parts[row.part],
          mobile: widget.mobile,
          time: turn.createdAt,
          continuation: row.part > 0,
          controls: row.part == row.partCount - 1,
          fullReply: turn.assistant,
          markdown: row.markdown,
          format: row.format,
          onNavigate: widget.onNavigate,
          onNotice: widget.onNotice,
        );
      case RoomTranscriptRowKind.actions:
        child = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeepseekDetails(controller: c, contextData: turn.deepseek),
            _RoomTurnActions(controller: c, turn: turn),
          ],
        );
      case RoomTranscriptRowKind.pending:
        child = _RoomPendingStatus(mobile: widget.mobile);
    }
    final result = RepaintBoundary(key: ValueKey(row.id), child: child);
    _rowWidgets[row.id] = (row, result);
    while (_rowWidgets.length > 192) {
      _rowWidgets.remove(_rowWidgets.keys.first);
    }
    return result;
  }

  SliverList _rows(
    RoomTranscriptRows rows, {
    bool title = false,
  }) => _RoomTranscriptSliver(
    delegate: SliverChildBuilderDelegate(
      (context, index) {
        final row = rows.rowAt(index);
        if (row != null) return _row(row);
        if (title && index == rows.knownRowCount) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Text(c.sharedConversation?['title']?.toString() ?? '公开对话片段'),
          );
        }
        return null;
      },
      childCount: rows.completeRowCount == null
          ? null
          : rows.completeRowCount! + (title ? 1 : 0),
      addRepaintBoundaries: false,
      findChildIndexCallback: (key) =>
          key is ValueKey<RoomTranscriptRowId> ? rows.indices[key.value] : null,
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical &&
                notification.metrics.extentAfter < 16 &&
                _unread.value) {
              _unread.value = false;
            }
            return false;
          },
          child: RepaintBoundary(
            key: const Key('chat-scroll-repaint'),
            child: CustomScrollView(
              key: ValueKey('conversation:$_scope'),
              controller: _scroll,
              center: _center,
              anchor: 1,
              scrollCacheExtent: ScrollCacheExtent.pixels(
                widget.mobile ? 240 : 320,
              ),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.mobile ? 16 : 1,
                  ),
                  sliver: _rows(
                    _index.history,
                    title: c.sharedConversation != null,
                  ),
                ),
                SliverPadding(
                  key: _center,
                  padding: EdgeInsets.fromLTRB(
                    widget.mobile ? 16 : 1,
                    0,
                    widget.mobile ? 16 : 1,
                    6,
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      _rows(_index.recent),
                      if (c.generating)
                        _RoomStreamingSliver(
                          controller: c,
                          mobile: widget.mobile,
                          onNavigate: widget.onNavigate,
                          onNotice: widget.onNotice,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ValueListenableBuilder<bool>(
        valueListenable: _unread,
        builder: (context, unread, _) => unread
            ? TextButton.icon(
                icon: const Icon(Icons.arrow_downward, size: 16),
                label: const SiteText('查看新消息'),
                onPressed: jumpToLatest,
              )
            : const SizedBox.shrink(),
      ),
    ],
  );

  @override
  void dispose() {
    c.removeListener(_changed);
    c.streamRevision.removeListener(_follow);
    _scroll.dispose();
    widget.onScrollActivity?.call(false);
    _unread.dispose();
    _rowWidgets.clear();
    _index.clear();
    _cache.clear();
    super.dispose();
  }
}

class _RoomPendingStatus extends StatelessWidget {
  const _RoomPendingStatus({required this.mobile});
  final bool mobile;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: SiteText(
      '已保存在本机 · 等待同步',
      style: TextStyle(
        fontSize: 10,
        color: mobile ? Colors.white : RoomStyle(context).muted,
      ),
    ),
  );
}

// A cached child can remain entirely unchanged when lazy metadata becomes
// complete. The delegate's changed child count must still invalidate geometry.
class _RoomTranscriptSliver extends SliverList {
  const _RoomTranscriptSliver({required super.delegate});
  @override
  void updateRenderObject(BuildContext context, RenderSliverList renderObject) {
    super.updateRenderObject(context, renderObject);
    renderObject.markNeedsLayout();
  }
}

class _RoomStreamingSliver extends StatefulWidget {
  const _RoomStreamingSliver({
    required this.controller,
    required this.mobile,
    required this.onNavigate,
    required this.onNotice,
  });
  final RoomController controller;
  final bool mobile;
  final ValueChanged<String> onNavigate, onNotice;
  @override
  State<_RoomStreamingSliver> createState() => _RoomStreamingSliverState();
}

class _RoomStreamingSliverState extends State<_RoomStreamingSliver> {
  late RoomReplyPresentation _reply;
  final _bubbles = <int, (String, Widget)>{};
  @override
  void initState() {
    super.initState();
    _read();
    widget.controller.streamRevision.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _RoomStreamingSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.streamRevision.removeListener(_changed);
      widget.controller.streamRevision.addListener(_changed);
      _read();
      _bubbles.clear();
    }
    if (oldWidget.mobile != widget.mobile) _bubbles.clear();
  }

  void _read() {
    final reply = cleanRoomReply(widget.controller.partial);
    _reply = RoomReplyPresentation(
      reply.isEmpty ? '正在想怎么回答你…' : reply,
      streaming: true,
    );
  }

  void _changed() {
    if (mounted) setState(_read);
  }

  @override
  void dispose() {
    widget.controller.streamRevision.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.controller.sendingText;
    final questionCount = question.isEmpty ? 0 : 1;
    return SliverList(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == questionCount + _reply.parts.length) {
          return DeepseekDetails(controller: widget.controller, live: true);
        }
        final user = index < questionCount;
        final part = index - questionCount;
        final text = user ? question : _reply.parts[part];
        final slot = user ? -1 : part;
        final found = _bubbles.remove(slot);
        if (found != null && found.$1 == text) {
          _bubbles[slot] = found;
          return found.$2;
        }
        final bubble = RoomChatBubble(
          key: ValueKey(user ? 'stream-question' : 'stream-part-$part'),
          controller: widget.controller,
          text: text,
          user: user,
          mobile: widget.mobile,
          streaming: true,
          continuation: !user && part > 0,
          onNavigate: widget.onNavigate,
          onNotice: widget.onNotice,
        );
        _bubbles[slot] = (text, bubble);
        while (_bubbles.length > 128) {
          _bubbles.remove(_bubbles.keys.first);
        }
        return bubble;
      }, childCount: questionCount + _reply.parts.length + 1),
    );
  }
}

class RoomChatImage extends StatelessWidget {
  const RoomChatImage({
    super.key,
    required this.controller,
    required this.cache,
    required this.image,
    this.height = 160,
  });
  final RoomController controller;
  final RoomMessageCache cache;
  final Map<String, dynamic> image;
  final double height;
  @override
  Widget build(BuildContext context) {
    final data = '${image['dataUrl'] ?? ''}', url = '${image['url'] ?? ''}';
    Widget error(BuildContext context, Object error, StackTrace? stack) =>
        const SiteText('图片暂不可用');
    try {
      final origin = endpointUri(controller.settings.siteUrl),
          remote = endpointUri(controller.settings.siteUrl).resolve(url);
      if (!data.startsWith('data:image/') &&
          !['https', 'http'].contains(remote.scheme)) {
        return const SiteText('图片地址不可用');
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: data.startsWith('data:image/')
            ? Image.memory(
                cache.image(data),
                height: height,
                cacheHeight: (height * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                fit: BoxFit.contain,
                errorBuilder: error,
              )
            : Image.network(
                remote.toString(),
                headers:
                    controller.site.cookie == null ||
                        remote.origin != origin.origin
                    ? null
                    : {'Cookie': controller.site.cookie!},
                height: height,
                cacheHeight: (height * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                fit: BoxFit.contain,
                errorBuilder: error,
              ),
      );
    } catch (_) {
      return const SiteText('图片暂不可用');
    }
  }
}

class RoomChatBubble extends StatelessWidget {
  const RoomChatBubble({
    super.key,
    required this.controller,
    required this.text,
    required this.onNavigate,
    required this.onNotice,
    this.user = false,
    this.mobile = false,
    this.streaming = false,
    this.continuation = false,
    this.controls = true,
    this.markdown = false,
    this.format = 'markdown',
    this.fullReply,
    this.time,
  });
  final RoomController controller;
  final String text, format;
  final ValueChanged<String> onNavigate, onNotice;
  final bool user, mobile, streaming, continuation, controls, markdown;
  final String? fullReply;
  final DateTime? time;
  RoomController get c => controller;
  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: user ? .82 : .93,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!user && !mobile) ...[
                continuation
                    ? const SizedBox.square(dimension: 20)
                    : const CharacterAvatar(size: 20, radius: 10),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: user
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!user && !continuation)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SiteText(
                              '八千代',
                              style: TextStyle(
                                fontSize: 10,
                                color: mobile ? Colors.white : p.muted,
                              ),
                            ),
                            if (!mobile) ...[
                              const SizedBox(width: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: p.soft,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: SiteText(
                                  'AI',
                                  style: TextStyle(fontSize: 7, color: p.muted),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: mobile
                            ? Colors.transparent
                            : user
                            ? Color.alphaBlend(
                                p.accent.withValues(alpha: .12),
                                mobile ? p.glass : p.surface,
                              )
                            : mobile
                            ? p.glass
                            : p.soft,
                        border: Border.all(
                          color: mobile
                              ? Colors.transparent
                              : p.line.withValues(alpha: .65),
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(user ? 20 : 4),
                          topRight: Radius.circular(user ? 4 : 20),
                          bottomLeft: const Radius.circular(20),
                          bottomRight: const Radius.circular(20),
                        ),
                      ),
                      child: markdown
                          ? NativeRichText(
                              content: text,
                              format: format,
                              trackReading: false,
                              site: c.settings.siteUrl,
                              onNavigate: (path) => onNavigate(path),
                            )
                          : SelectableText(
                              text,
                              style: TextStyle(
                                fontSize: mobile ? 14 : 13,
                                height: 1.8,
                                color: user ? p.accent : p.ink,
                              ),
                            ),
                    ),
                    if (!streaming && controls)
                      _RoomReplyControls(
                        controller: c,
                        mobile: mobile,
                        user: user,
                        text: fullReply ?? text,
                        time: time,
                        onNotice: onNotice,
                      ),
                  ],
                ),
              ),
              if (user && !mobile) ...[
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 10,
                  backgroundColor: p.soft,
                  child: SiteText(
                    '你',
                    style: TextStyle(fontSize: 9, height: 1.15, color: p.muted),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomReplyControls extends StatefulWidget {
  const _RoomReplyControls({
    required this.controller,
    required this.mobile,
    required this.user,
    required this.text,
    required this.time,
    required this.onNotice,
  });
  final RoomController controller;
  final bool mobile, user;
  final String text;
  final DateTime? time;
  final ValueChanged<String> onNotice;
  @override
  State<_RoomReplyControls> createState() => _RoomReplyControlsState();
}

class _RoomReplyControlsState extends State<_RoomReplyControls> {
  late bool _playing;
  @override
  void initState() {
    super.initState();
    _playing = widget.controller.voice.playing;
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _RoomReplyControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _playing = widget.controller.voice.playing;
    }
  }

  void _changed() {
    final playing = widget.controller.voice.playing;
    if (playing != _playing && mounted) setState(() => _playing = playing);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context), time = widget.time, c = widget.controller;
    final style = IconButton.styleFrom(
      minimumSize: Size(32, widget.mobile ? 36 : 26),
      padding: const EdgeInsets.all(4),
    );
    final color = widget.mobile ? Colors.white : p.muted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (time != null)
          Text(
            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
            style: TextStyle(
              fontSize: 9,
              color: widget.mobile ? Colors.white70 : p.muted,
            ),
          ),
        if (!widget.user) ...[
          IconButton(
            tooltip: siteTranslate(context, '复制回复'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.text));
              widget.onNotice('已复制回复');
            },
            style: style,
            icon: Icon(CupertinoIcons.doc_on_doc, size: 12, color: color),
          ),
          IconButton(
            tooltip: _playing ? '停止语音' : '朗读回复',
            onPressed: () =>
                c.voice.playing ? c.voice.stop() : c.replay(widget.text),
            style: style,
            icon: Icon(
              _playing ? CupertinoIcons.stop : CupertinoIcons.speaker_2,
              size: 13,
              color: color,
            ),
          ),
        ],
      ],
    );
  }
}

class _RoomTurnActions extends StatefulWidget {
  const _RoomTurnActions({required this.controller, required this.turn});
  final RoomController controller;
  final ChatTurn turn;
  @override
  State<_RoomTurnActions> createState() => _RoomTurnActionsState();
}

class _RoomTurnActionsState extends State<_RoomTurnActions> {
  Object? _stamp;
  Object _snapshot() => (
    widget.controller.canSend,
    widget.controller.isSharedTurn(widget.turn),
    widget.controller.visibleTurns.lastOrNull?.id,
  );
  @override
  void initState() {
    super.initState();
    _stamp = _snapshot();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _RoomTurnActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _stamp = _snapshot();
  }

  void _changed() {
    final next = _snapshot();
    if (_stamp != next && mounted) setState(() => _stamp = next);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, turn = widget.turn;
    final last = c.visibleTurns.lastOrNull?.id == turn.id;
    return Wrap(
      alignment: WrapAlignment.end,
      children: [
        if (!c.isSharedTurn(turn) &&
            !turn.pending &&
            turn.image == null &&
            (turn.deepseek?['user']?['files'] as List? ?? []).isEmpty &&
            last) ...[
          if (turn.user.isNotEmpty)
            TextButton(
              onPressed: c.canSend
                  ? () => editRoomTurn(context, c, turn)
                  : null,
              child: const SiteText('编辑'),
            ),
          TextButton(
            onPressed: c.canSend
                ? () => c.send(
                    turn.user,
                    opener: turn.user.isEmpty,
                    replacement: turn,
                  )
                : null,
            child: const SiteText('重新生成'),
          ),
        ],
        if (!c.isSharedTurn(turn) &&
            turn.user.isNotEmpty &&
            turn.image == null &&
            (turn.deepseek?['user']?['files'] as List? ?? []).isEmpty)
          TextButton(
            onPressed: c.canSend ? () => shareRoomTurn(context, c, turn) : null,
            child: const SiteText('分享'),
          ),
      ],
    );
  }
}

/// The archive dialog uses the same incremental row data and rich reply UI.
/// Opening history never mounts every turn or every sentence at once.
class RoomChatHistoryView extends StatefulWidget {
  const RoomChatHistoryView({
    super.key,
    required this.controller,
    required this.onNavigate,
    required this.onNotice,
    this.mobile = false,
  });
  final RoomController controller;
  final ValueChanged<String> onNavigate, onNotice;
  final bool mobile;
  @override
  State<RoomChatHistoryView> createState() => _RoomChatHistoryViewState();
}

class _RoomChatHistoryViewState extends State<RoomChatHistoryView> {
  final _cache = RoomMessageCache();
  late final _index = RoomTranscriptIndex(_cache);
  Object? _stamp;
  String _scope = '';
  RoomController get c => widget.controller;
  Object _snapshot() => (c.scope, c.turns, c.settings.siteUrl, c.site.cookie);
  @override
  void initState() {
    super.initState();
    _read();
    c.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant RoomChatHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(_changed);
      c.addListener(_changed);
      _scope = '';
      _read();
    }
  }

  void _read() {
    if (_scope != c.scope) {
      _scope = c.scope;
      _cache.clear();
      _index.clear();
    }
    _index.update(c.turns, (_) => false);
    _stamp = _snapshot();
  }

  void _changed() {
    if (mounted && _snapshot() != _stamp) setState(_read);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    _index.clear();
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _index.recent;
    return ListView.builder(
      key: ValueKey('history:$_scope'),
      itemCount: rows.completeRowCount,
      findChildIndexCallback: (key) =>
          key is ValueKey<RoomTranscriptRowId> ? rows.indices[key.value] : null,
      itemBuilder: (context, index) {
        final row = rows.rowAt(index);
        if (row == null) return null;
        final turn = row.turn;
        final Widget child;
        switch (row.kind) {
          case RoomTranscriptRowKind.question:
            child = RoomChatBubble(
              controller: c,
              text: turn.user,
              user: true,
              time: turn.createdAt,
              mobile: widget.mobile,
              onNavigate: widget.onNavigate,
              onNotice: widget.onNotice,
            );
          case RoomTranscriptRowKind.reply:
            child = RoomChatBubble(
              controller: c,
              text: _index.presentation(turn).parts[row.part],
              mobile: widget.mobile,
              time: turn.createdAt,
              continuation: row.part > 0,
              controls: row.part == row.partCount - 1,
              markdown: row.markdown,
              format: row.format,
              fullReply: turn.assistant,
              onNavigate: widget.onNavigate,
              onNotice: widget.onNotice,
            );
          case RoomTranscriptRowKind.image:
            child = Align(
              alignment: Alignment.centerRight,
              child: RoomChatImage(
                controller: c,
                cache: _cache,
                image: turn.image!,
              ),
            );
          case RoomTranscriptRowKind.actions:
          case RoomTranscriptRowKind.pending:
            child = const SizedBox.shrink();
        }
        return RepaintBoundary(key: ValueKey(row.id), child: child);
      },
    );
  }
}
