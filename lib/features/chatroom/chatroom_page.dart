import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/site_localization.dart';
import '../room/room_controller.dart';
import '../site/login_dialog.dart';
import '../site/site_widgets.dart';
import 'chatroom_copy.dart';
import 'chatroom_session.dart';

class ChatroomPage extends StatefulWidget {
  const ChatroomPage({
    super.key,
    required this.controller,
    required this.onGo,
    this.channel,
  });
  final RoomController controller;
  final ValueChanged<String> onGo;
  final String? channel;
  @override
  State<ChatroomPage> createState() => _ChatroomPageState();
}

class _ChatroomPageState extends State<ChatroomPage>
    with WidgetsBindingObserver {
  final scaffold = GlobalKey<ScaffoldState>();
  final input = TextEditingController(), feed = ScrollController();
  final focus = FocusNode();
  late final ChatroomSession session;
  ChannelDraft? displayed;
  bool current = false, foreground = true, roster = false, newBelow = false;
  int lastId = 0;
  String get language => SiteLocaleScope.maybeOf(context)?.language ?? 'zh';
  String t(String key) =>
      (chatroomCopy[language] ?? chatroomCopy['zh']!)[key] ?? key;
  String get mention => switch (language) {
    'ja' => '@ヤチヨ',
    'en' => '@Yachiyo',
    _ => '@八千代',
  };
  bool get compact => MediaQuery.sizeOf(context).width <= 760;
  @override
  void initState() {
    super.initState();
    session = ChatroomSession(widget.controller, widget.channel)
      ..addListener(_changed);
    focus.onKeyEvent = (node, event) {
      final platform = Theme.of(context).platform;
      if (!{
            TargetPlatform.macOS,
            TargetPlatform.windows,
            TargetPlatform.linux,
          }.contains(platform) ||
          event.logicalKey != LogicalKeyboardKey.enter &&
              event.logicalKey != LogicalKeyboardKey.numpadEnter ||
          HardwareKeyboard.instance.isShiftPressed ||
          !input.value.composing.isCollapsed) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent) {
        unawaited(session.send());
      }
      return KeyEventResult.handled;
    };
    displayed = session.draft;
    WidgetsBinding.instance.addObserver(this);
    feed.addListener(_scroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    current = ModalRoute.isCurrentOf(context) ?? true;
    session.activate(current && foreground);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    session.activate(current && foreground);
  }

  void _scroll() {
    if (newBelow && feed.hasClients && feed.offset < 85) {
      setState(() => newBelow = false);
    }
  }

  void _changed() {
    if (!mounted) return;
    final draft = session.draft;
    if (!identical(draft, displayed)) {
      lastId = 0;
      newBelow = false;
      roster = false;
      displayed = draft;
      if (feed.hasClients) feed.jumpTo(0);
    }
    if (input.text != draft.text) {
      input.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
    }
    final id = session.messages.lastKey() ?? 0;
    if (lastId != 0 && id > lastId && feed.hasClients && feed.offset >= 85) {
      newBelow = true;
    }
    lastId = id;
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.dispose();
    input.dispose();
    feed.dispose();
    focus.dispose();
    super.dispose();
  }

  void _login() => showSiteLogin(context, widget.controller);
  void _mention() {
    if (session.user == null) {
      _login();
      return;
    }
    if (!RegExp(
      r'[@＠](?:月见八千代|月見八千代|八千代|ヤチヨ|yachiyo\b)',
      caseSensitive: false,
    ).hasMatch(input.text)) {
      session.draft.text = '$mention ${input.text}';
      _changed();
    }
    focus.requestFocus();
  }

  void _notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  Future<void> _action(int id, String action) async {
    try {
      await session.action(id, action);
      if (mounted && {'report', 'mute'}.contains(action)) {
        _notice(t(action == 'mute' ? 'muted' : 'reported'));
      }
    } catch (error) {
      if (mounted) _notice('$error');
    }
  }

  Future<void> _manage() async {
    final owner = session.user, origin = widget.controller.settings.siteUrl;
    try {
      final data = await session.reports();
      if (!mounted || !session.moderator || session.user != owner) return;
      final rows = rowsOf(data['items']);
      final choice = await showDialog<(int, String)>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(t('manage')),
          children: [
            ListTile(
              title: Text('${t('active')} · ${data['activeToday'] ?? 0}'),
            ),
            if (rows.isEmpty) ListTile(title: Text(t('noReports'))),
            for (final row in rows)
              ListTile(
                title: Text(textOf(row, 'content')),
                subtitle: Text('${row['nickname'] ?? ''} · ${row['reports']}'),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) =>
                      Navigator.pop(ctx, (row['id'] as int, action)),
                  itemBuilder: (_) => [
                    for (final a in ['dismiss', 'remove', 'mute'])
                      PopupMenuItem(
                        value: a,
                        child: Text(t(a == 'remove' ? 'withdraw' : a)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
      if (mounted &&
          choice != null &&
          session.moderator &&
          owner == session.user &&
          origin == widget.controller.settings.siteUrl) {
        await _action(choice.$1, choice.$2);
      }
    } catch (error) {
      if (mounted) _notice('$error');
    }
  }

  Widget logo() => IconButton(
    tooltip: t('hub'),
    onPressed: () => widget.onGo('/hub'),
    icon: Image.asset('assets/images/sakura/sakura-moon-logo.webp', width: 34),
  );
  Widget channels() => Material(
    color: const Color(0xff252737),
    child: DefaultTextStyle(
      style: const TextStyle(color: Colors.white),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 104,
            alignment: Alignment.topLeft,
            decoration: const BoxDecoration(
              image: DecorationImage(
                image: AssetImage(
                  'assets/images/navigation/plaza-gathering.webp',
                ),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(Colors.black54, BlendMode.darken),
              ),
            ),
            child: Row(
              children: [
                logo(),
                Expanded(
                  child: Text(
                    t('title'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(10),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  child: Text(
                    t('channels'),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                for (final id in channelIds)
                  ListTile(
                    dense: true,
                    textColor: Colors.white,
                    iconColor: Colors.white70,
                    selectedColor: Colors.white,
                    selectedTileColor: const Color(0xff45465b),
                    selected: id == session.channel,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    leading: const Icon(Icons.tag),
                    title: Text(t('channel_$id')),
                    trailing: session.unread.contains(id)
                        ? const Icon(Icons.circle, size: 8)
                        : null,
                    onTap: () {
                      if (compact) scaffold.currentState?.closeDrawer();
                      session.select(id);
                    },
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              '●  ${t(session.status)}',
              style: TextStyle(
                color: session.status == 'live'
                    ? const Color(0xffa7d9c3)
                    : Colors.white70,
                fontSize: 12,
              ),
            ),
          ),
          ListTile(
            textColor: Colors.white,
            iconColor: Colors.white70,
            leading: const Icon(Icons.auto_awesome),
            title: Text(t('growth')),
            subtitle: Text(
              session.rewarded ? t('awarded') : '${t('xp')} +5 XP',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            trailing: session.moderator
                ? IconButton(
                    onPressed: _manage,
                    tooltip: t('manage'),
                    icon: const Icon(Icons.shield_outlined),
                  )
                : null,
          ),
        ],
      ),
    ),
  );
  Widget memberList() => Material(
    color: Theme.of(context).colorScheme.surface,
    child: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ListTile(
          title: Text('${t('online')} · ${session.members.length}'),
          trailing: IconButton(
            tooltip: t('close'),
            onPressed: () {
              if (compact) {
                scaffold.currentState?.closeEndDrawer();
              } else {
                setState(() => roster = false);
              }
            },
            icon: const Icon(Icons.close),
          ),
        ),
        ListTile(
          leading: avatar({}),
          title: Text(t('yachiyo')),
          subtitle: Text(t('aiHint')),
          onTap: () {
            if (compact) scaffold.currentState?.closeEndDrawer();
            _mention();
          },
        ),
        for (final m in session.members)
          ListTile(title: Text(textOf(m, 'name'))),
        if (session.members.isEmpty) ListTile(title: Text(t('noMembers'))),
      ],
    ),
  );
  String speaker(Map m) =>
      m['userId'] == null ? t('yachiyo') : textOf(m, 'nickname');
  Widget avatar(Map m) => m['userId'] == null
      ? const CircleAvatar(
          radius: 18,
          backgroundImage: AssetImage(
            'assets/images/sakura/yachiyo-portrait.webp',
          ),
        )
      : SiteAvatar(
          value: textOf(m, 'avatar'),
          name: speaker(m),
          site: widget.controller.settings.siteUrl,
          size: 36,
        );
  Widget message(Map<String, dynamic> m) {
    final id = m['id'] as int, removed = m['removed'] == true;
    final stamp = m['createdAt'] as num?;
    final date = stamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(stamp.toInt());
    return Padding(
      key: ValueKey(id),
      padding: const EdgeInsets.fromLTRB(16, 7, 8, 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          avatar(m),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      speaker(m),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      m['userId'] == null ? 'AI' : 'Lv.${m['level'] ?? 1}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (date != null)
                      Text(
                        MaterialLocalizations.of(context).formatTimeOfDay(
                          TimeOfDay.fromDateTime(date),
                          alwaysUse24HourFormat: language != 'en',
                        ),
                        style: const TextStyle(fontSize: 11),
                      ),
                  ],
                ),
                if (!removed && m['quote'] != null)
                  Text(
                    '↳ ${m['quote']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                SelectableText(removed ? t('removed') : textOf(m, 'content')),
                if (['pending', 'failed'].contains(m['aiStatus']))
                  Text(
                    t(m['aiStatus'] == 'pending' ? 'waiting' : 'failed'),
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
          ),
          if (!removed && session.user != null)
            PopupMenuButton<String>(
              tooltip: t('actions'),
              iconSize: 17,
              onSelected: (a) {
                if (a == 'reply') {
                  session.setReply(id);
                  focus.requestFocus();
                } else {
                  unawaited(_action(id, a));
                }
              },
              itemBuilder: (_) => [
                for (final a in [
                  'reply',
                  if ('${m['userId']}' != session.user) 'report',
                  if ('${m['userId']}' == session.user || session.moderator)
                    'remove',
                  if (session.moderator && m['userId'] != null) 'mute',
                ])
                  PopupMenuItem(
                    value: a,
                    child: Text(t(a == 'remove' ? 'withdraw' : a)),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget timeline() {
    final rows = session.messages.values
        .toList(growable: false)
        .reversed
        .toList(growable: false);
    if (rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tag),
            Text(t(session.status == 'live' ? 'first' : session.status)),
            Text(
              session.status == 'live'
                  ? t('invite')
                  : t('channel_${session.channel}'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: feed,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length + (session.older ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == rows.length) {
          return TextButton(
            onPressed: session.loadingOlder ? null : session.earlier,
            child: Text(t('older')),
          );
        }
        final row = rows[i];
        final stamp = row['createdAt'];
        final date = stamp is int
            ? DateTime.fromMillisecondsSinceEpoch(stamp)
            : null;
        final prev = i + 1 < rows.length ? rows[i + 1]['createdAt'] : null;
        if (date != null &&
            (prev is! int ||
                !DateUtils.isSameDay(
                  date,
                  DateTime.fromMillisecondsSinceEpoch(prev),
                ))) {
          return Column(
            children: [
              Text(
                MaterialLocalizations.of(context).formatShortDate(date),
                style: const TextStyle(fontSize: 12),
              ),
              message(row),
            ],
          );
        }
        return message(row);
      },
    );
  }

  Widget composer() => Container(
    margin: const EdgeInsets.all(12),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (newBelow)
          TextButton(onPressed: () => feed.jumpTo(0), child: Text(t('jump'))),
        if (session.feedback.isNotEmpty) Text(session.feedback),
        if (session.user == null)
          Row(
            children: [
              Expanded(child: Text(t('guest'))),
              FilledButton(onPressed: _login, child: Text(t('login'))),
            ],
          )
        else ...[
          if (session.draft.replyTo != null)
            ListTile(
              dense: true,
              title: Text(
                '${t('reply')} · ${speaker(session.messages[session.draft.replyTo] ?? {})}',
              ),
              trailing: IconButton(
                onPressed: () => session.setReply(null),
                tooltip: t('cancel'),
                icon: const Icon(Icons.close),
              ),
            ),
          Row(
            children: [
              IconButton(
                onPressed: session.draft.sending ? null : _mention,
                tooltip: '$mention · ${t('free')}',
                icon: avatar({}),
              ),
              Expanded(
                child: TextField(
                  controller: input,
                  focusNode: focus,
                  readOnly: session.draft.sending,
                  maxLength: 4000,
                  minLines: 1,
                  maxLines: 4,
                  onChanged: (v) => setState(() => session.draft.text = v),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText:
                        "${t('placeholder')} #${t('channel_${session.channel}')}…",
                  ),
                ),
              ),
              IconButton(
                onPressed: session.draft.sending || input.text.trim().isEmpty
                    ? null
                    : session.send,
                tooltip: t('send'),
                icon: const Icon(Icons.send_outlined),
              ),
            ],
          ),
        ],
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    key: scaffold,
    backgroundColor: Theme.of(context).brightness == Brightness.light
        ? Colors.white
        : Theme.of(context).colorScheme.surface,
    drawer: compact ? Drawer(child: SafeArea(child: channels())) : null,
    endDrawer: compact ? Drawer(child: SafeArea(child: memberList())) : null,
    body: SafeArea(
      child: Row(
        children: [
          if (!compact) SizedBox(width: 230, child: channels()),
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      if (compact) logo() else const SizedBox(width: 20),
                      if (compact)
                        Flexible(
                          child: TextButton.icon(
                            onPressed: () =>
                                scaffold.currentState?.openDrawer(),
                            label: Text(
                              '#  ${t('channel_${session.channel}')}',
                            ),
                            icon: const Icon(Icons.expand_more),
                            iconAlignment: IconAlignment.end,
                          ),
                        )
                      else
                        Text(
                          '#  ${t('channel_${session.channel}')}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      if (!compact)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              t('topic_${session.channel}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      IconButton(
                        tooltip: '${t('online')} · ${session.members.length}',
                        onPressed: () {
                          if (compact) {
                            scaffold.currentState?.openEndDrawer();
                          } else {
                            setState(() => roster = !roster);
                          }
                        },
                        icon: const Icon(Icons.people_outline),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: timeline()),
                composer(),
              ],
            ),
          ),
          if (!compact && roster) SizedBox(width: 220, child: memberList()),
        ],
      ),
    ),
  );
}
