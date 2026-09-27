import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../../core/models.dart';
import '../../live2d/character_stage.dart';
import '../settings/settings_dialog.dart';
import '../site/login_dialog.dart';
import 'room_controller.dart';
import 'room_panels.dart';
import 'room_style.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    required this.controller,
    this.loadNative = true,
    this.onToggleTheme,
    this.modelLoader,
    this.onNavigate,
  });
  final RoomController controller;
  final ValueChanged<String>? onNavigate;
  final bool loadNative;
  final VoidCallback? onToggleTheme;
  final Future<Live2DModel> Function()? modelLoader;
  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  final _input = TextEditingController(), _scroll = ScrollController();
  final _focus = FocusNode();
  final _stageKey = GlobalKey();
  String _lastScope = '', _lastDraft = '', _panel = '聊天';
  bool _ready = false, _quiet = false;
  RoomController get c => widget.controller;
  static const _tabs = <String, IconData>{
    '聊天': CupertinoIcons.chat_bubble,
    '日记': CupertinoIcons.book,
    '资料': CupertinoIcons.person,
    '便签': CupertinoIcons.doc_text,
  };
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastScope = c.scope;
    _lastDraft = c.draft;
    _input.text = c.draft;
    c.addListener(_update);
    _input.addListener(_inputChanged);
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    _input.removeListener(_inputChanged);
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
      if (!c.generating) _input.text = c.draft;
      _lastScope = c.scope;
      _lastDraft = c.draft;
    }
    final nearBottom =
        !_scroll.hasClients || _scroll.position.extentAfter < 100;
    setState(() {});
    if (nearBottom && (c.visibleTurns.isNotEmpty || c.generating)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    if (_input.text.trim().isEmpty || !c.canSend) return;
    final value = _input.text;
    // Keep rejected oversized input visible, matching controller validation.
    if (value.trim().length > 12000) {
      unawaited(c.send(value));
      return;
    }
    _input.clear();
    unawaited(c.send(value));
  }

  void _settings() => unawaited(showRoomSettings(context, c));
  void _account() {
    if (c.account != null && !c.sessionExpired && widget.onNavigate != null) {
      widget.onNavigate!('/user');
    } else {
      unawaited(showSiteLogin(context, c));
    }
  }

  void _notice(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
  Future<void> _website(String path) async {
    if (widget.onNavigate != null &&
        [
          '/stage',
          '/plaza',
          '/growth',
          '/user',
          '/conversations',
          '/notifications',
          '/hub',
        ].contains(path)) {
      widget.onNavigate!(path == '/hub' ? '/stage' : path);
      return;
    }
    try {
      final uri = endpointUri(c.settings.siteUrl).resolve(path);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        _notice('暂时无法打开网站');
      }
    } catch (_) {
      if (mounted) _notice('暂时无法打开网站');
    }
  }

  Future<void> _newConversation() async {
    try {
      await c.startConversation();
      if (mounted && c.canSend) {
        setState(() {
          _panel = '聊天';
          _quiet = false;
          _input.clear();
        });
      }
    } catch (_) {
      if (mounted) _notice('新建会话失败，原对话已保留');
    }
  }

  void _endConversation() {
    c.stop();
    _notice('对话已保存在本机，可从历史记录中查看。');
  }

  void _music() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('房间音乐'),
      content: const Text('此版本尚未接入音乐库，可以前往网站播放。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            _website('/room');
          },
          child: const Text('打开网站'),
        ),
      ],
    ),
  );
  void _selectPanel(String panel) {
    if (panel == '日记' && widget.onNavigate != null) {
      widget.onNavigate!('/conversations?tab=diary');
      return;
    }
    setState(() {
      _panel = panel;
      _quiet = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = RoomStyle(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final mobile = box.maxWidth <= RoomStyle.breakpoint;
              final landscape = mobile && box.maxHeight < 500 && keyboard == 0;
              final stage = CharacterStage(
                key: _stageKey,
                voice: c.voice,
                loadNative: widget.loadNative,
                modelLoader: widget.modelLoader,
                mobile: mobile,
                keyboardOpen: keyboard > 0,
                onSettings: _settings,
                onMusic: _music,
                onReady: (value) {
                  if (mounted) setState(() => _ready = value);
                },
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (!mobile) ...[
                    Image.asset(
                      'assets/images/moonlit-lake.png',
                      fit: BoxFit.cover,
                      excludeFromSemantics: true,
                    ),
                    ColoredBox(color: p.background.withValues(alpha: .82)),
                    Positioned(
                      left: 24,
                      right: 24,
                      top: 104,
                      bottom: 20,
                      child: Row(
                        children: [
                          Expanded(flex: 138, child: stage),
                          const SizedBox(width: 17),
                          Expanded(flex: 100, child: _desktopWorkspace()),
                        ],
                      ),
                    ),
                  ] else ...[
                    Positioned.fill(child: stage),
                    Positioned(top: 82, left: 16, child: _mobileTools()),
                    Positioned(
                      top: 82,
                      right: 16,
                      child: _roundButton(
                        '房间设置',
                        CupertinoIcons.gear_alt,
                        _settings,
                      ),
                    ),
                    if (!_quiet)
                      Positioned(
                        key: const Key('mobile-conversation'),
                        top: keyboard > 0
                            ? math.min(
                                math.max(134, (box.maxHeight - keyboard) * .24),
                                math.max(84, box.maxHeight - keyboard - 100),
                              )
                            : landscape
                            ? 134
                            : box.maxHeight * (box.maxHeight < 700 ? .39 : .44),
                        left: landscape ? box.maxWidth * .35 : 0,
                        right: 0,
                        bottom: keyboard + 12,
                        child: _panel == '聊天'
                            ? _conversation(
                                mobile: true,
                                keyboard: keyboard > 0,
                                short: box.maxHeight < 700,
                              )
                            : _mobilePanel(),
                      ),
                  ],
                  Positioned(
                    top: mobile ? 10 : 16,
                    left: mobile ? 12 : math.max(24, (box.maxWidth - 1320) / 2),
                    right: mobile
                        ? 12
                        : math.max(24, (box.maxWidth - 1320) / 2),
                    height: mobile ? 60 : 68,
                    child: _siteHeader(mobile: mobile, width: box.maxWidth),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _siteHeader({required bool mobile, required double width}) {
    final p = RoomStyle(context);
    return Container(
      key: const Key('site-header'),
      padding: EdgeInsets.symmetric(horizontal: mobile ? 14 : 20, vertical: 10),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .035),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        children: [
          if (!mobile) ...[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: p.soft, shape: BoxShape.circle),
              child: Icon(CupertinoIcons.moon_stars, color: p.accent, size: 23),
            ),
            const SizedBox(width: 12),
          ],
          Semantics(
            header: true,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '月读空间',
                  style: TextStyle(
                    fontFamily: RoomStyle.serif,
                    fontSize: mobile ? 20 : 23,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: mobile ? 0 : 2,
                    color: p.ink,
                  ),
                ),
                Text(
                  '私人居所',
                  style: TextStyle(fontSize: 9, height: 1.15, color: p.muted),
                ),
              ],
            ),
          ),
          const Spacer(),
          if (!mobile && width >= 1180)
            for (final entry in const {
              '中枢': '/hub',
              '舞台': '/stage',
              '广场': '/plaza',
              '成长': '/growth',
              '记忆': '/conversations',
            }.entries)
              TextButton(
                onPressed: () => _website(entry.value),
                style: TextButton.styleFrom(
                  foregroundColor: p.muted,
                  minimumSize: const Size(50, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(entry.key, style: const TextStyle(fontSize: 12)),
              ),
          if (!mobile) _explore(mobile: false),
          if (!mobile) const SizedBox(width: 16),
          if (!mobile && width >= 1080)
            InkWell(
              onTap: _search,
              borderRadius: BorderRadius.circular(30),
              child: Container(
                width: width >= 1300 ? 166 : 132,
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: p.soft,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.search, size: 16, color: p.muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '搜索月读空间',
                        style: TextStyle(fontSize: 11, color: p.muted),
                      ),
                    ),
                    if (width >= 1300)
                      Text(
                        '⌘ K',
                        style: TextStyle(
                          fontSize: 9,
                          height: 1.15,
                          color: p.muted,
                        ),
                      ),
                  ],
                ),
              ),
            )
          else
            _headerIcon('搜索月读空间', CupertinoIcons.search, _search),
          if (!mobile)
            _headerIcon(
              p.dark ? '切换浅色主题' : '切换深色主题',
              p.dark ? CupertinoIcons.sun_max : CupertinoIcons.moon,
              widget.onToggleTheme,
            ),
          _headerIcon(
            '账号菜单',
            CupertinoIcons.person_crop_circle,
            c.loading || c.busy || c.generating ? null : _account,
          ),
          if (!mobile) ...[
            TextButton(
              onPressed: c.loading || c.generating || c.busy ? null : _account,
              child: Text(
                c.sessionExpired ? '重新登录' : c.account?.username ?? '登录',
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _selectPanel('聊天'),
              style: OutlinedButton.styleFrom(
                backgroundColor: p.selected,
                foregroundColor: p.accent,
                side: BorderSide(color: p.accent.withValues(alpha: .35)),
                minimumSize: const Size(0, 40),
              ),
              icon: const Icon(CupertinoIcons.moon, size: 16),
              label: const Text('进入房间', style: TextStyle(fontSize: 11)),
            ),
          ] else
            _explore(mobile: true),
        ],
      ),
    );
  }

  Widget _headerIcon(String label, IconData icon, VoidCallback? tap) =>
      IconButton(
        tooltip: label,
        onPressed: tap,
        icon: Icon(icon, size: 19),
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.all(8),
        ),
      );
  Widget _explore({required bool mobile}) => PopupMenuButton<String>(
    tooltip: '探索',
    onSelected: (v) {
      if (v == 'theme') {
        widget.onToggleTheme?.call();
      } else if (v == 'settings') {
        _settings();
      } else {
        _website(v);
      }
    },
    itemBuilder: (_) => [
      for (final e in const {
        '中枢': '/hub',
        '主舞台': '/stage',
        '月读广场': '/plaza',
        '成长': '/growth',
        '记忆': '/conversations',
      }.entries)
        PopupMenuItem(value: e.value, child: Text(e.key)),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'theme', child: Text('切换浅色 / 深色')),
      const PopupMenuItem(value: 'settings', child: Text('房间设置')),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9),
      child: mobile
          ? const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.line_horizontal_3, size: 21),
                Text('探索', style: TextStyle(fontSize: 9)),
              ],
            )
          : const Row(
              children: [
                Text('探索', style: TextStyle(fontSize: 12)),
                SizedBox(width: 4),
                Icon(CupertinoIcons.chevron_down, size: 10),
              ],
            ),
    ),
  );

  Widget _roundButton(String label, IconData icon, VoidCallback action) {
    final p = RoomStyle(context);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: p.glass,
        shape: BoxShape.circle,
        border: Border.all(color: p.line),
      ),
      child: IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon, size: 23, color: p.ink),
      ),
    );
  }

  Widget _mobileTools() {
    final p = RoomStyle(context);
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: p.glass,
        shape: BoxShape.circle,
        border: Border.all(color: p.line),
      ),
      child: PopupMenuButton<String>(
        tooltip: '房间功能',
        offset: const Offset(0, 54),
        icon: const Icon(CupertinoIcons.chat_bubble, size: 23),
        onSelected: (v) {
          if (_tabs.containsKey(v)) {
            _selectPanel(v);
          } else if (v == 'new') {
            _newConversation();
          } else if (v == 'history') {
            _history();
          } else if (v == 'quiet') {
            setState(() => _quiet = !_quiet);
          } else if (v == 'music') {
            _music();
          } else if (v == 'end') {
            _endConversation();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem<String>(enabled: false, child: Text('这一刻，慢慢聊')),
          PopupMenuItem(
            value: 'new',
            enabled: c.canSend,
            child: const Text('新建会话'),
          ),
          const PopupMenuItem(value: 'history', child: Text('查看对话开头')),
          for (final e in _tabs.entries)
            PopupMenuItem(
              value: e.key,
              child: Row(
                children: [
                  Icon(e.value, size: 18),
                  const SizedBox(width: 12),
                  Text(e.key),
                ],
              ),
            ),
          const PopupMenuItem(value: 'music', child: Text('房间音乐')),
          PopupMenuItem(value: 'quiet', child: Text(_quiet ? '返回聊天' : '安静陪伴')),
          const PopupMenuItem(value: 'end', child: Text('结束聊天')),
        ],
      ),
    );
  }

  Widget _desktopWorkspace() {
    final p = RoomStyle(context);
    return Container(
      key: const Key('desktop-workspace'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 11),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(21),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const CharacterAvatar(),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '八千代',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 4,
                          color: _ready ? const Color(0xff87c8b1) : p.muted,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            c.generating ? '正在认真回应你…' : '在这里，陪着你',
                            style: TextStyle(fontSize: 10, color: p.muted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '查看对话历史',
                onPressed: c.turns.isEmpty ? null : _history,
                icon: const Icon(CupertinoIcons.arrow_uturn_left, size: 17),
              ),
              OutlinedButton.icon(
                onPressed: c.canSend ? _newConversation : null,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 29),
                  side: BorderSide(color: p.line),
                ),
                icon: const Icon(CupertinoIcons.plus, size: 12),
                label: const Text('新建会话', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 43,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final e in _tabs.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Semantics(
                              selected: _panel == e.key,
                              button: true,
                              child: TextButton.icon(
                                onPressed: () => _selectPanel(e.key),
                                style: TextButton.styleFrom(
                                  backgroundColor: _panel == e.key
                                      ? p.selected
                                      : null,
                                  foregroundColor: _panel == e.key
                                      ? p.accent
                                      : p.muted,
                                  minimumSize: const Size(0, 30),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                  ),
                                ),
                                icon: Icon(e.value, size: 16),
                                label: Text(
                                  e.key,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '房间设置',
                  onPressed: _settings,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(30, 30),
                    padding: const EdgeInsets.all(4),
                  ),
                  icon: const Icon(CupertinoIcons.gear_alt, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: _panel == '聊天'
                ? _conversation(mobile: false)
                : _utilityPanel(),
          ),
        ],
      ),
    );
  }

  Widget _utilityPanel() => RoomUtilityPanel(
    key: ValueKey('${c.scope}:$_panel'),
    panel: _panel,
    controller: c,
    onSettings: _settings,
    onOpenWebsite: () => _website('/room'),
  );
  Widget _mobilePanel() {
    final p = RoomStyle(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.line),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(_panel, style: const TextStyle(fontSize: 18)),
              const Spacer(),
              IconButton(
                tooltip: '返回聊天',
                onPressed: () => _selectPanel('聊天'),
                icon: const Icon(CupertinoIcons.xmark, size: 18),
              ),
            ],
          ),
          Expanded(child: _utilityPanel()),
        ],
      ),
    );
  }

  Widget _conversation({
    required bool mobile,
    bool keyboard = false,
    bool short = false,
  }) {
    final turns = c.visibleTurns;
    final p = RoomStyle(context);
    return Column(
      children: [
        Expanded(
          child: c.loading && turns.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : turns.isEmpty && !c.generating
              ? _welcome(mobile: mobile, short: short || keyboard)
              : ListView(
                  controller: _scroll,
                  padding: EdgeInsets.fromLTRB(
                    mobile ? 16 : 1,
                    mobile ? 40 : 12,
                    mobile ? 16 : 1,
                    6,
                  ),
                  children: [
                    for (final turn in turns) ...[
                      _bubble(
                        turn.user,
                        user: true,
                        mobile: mobile,
                        time: turn.createdAt,
                      ),
                      _bubble(
                        turn.assistant,
                        mobile: mobile,
                        time: turn.createdAt,
                      ),
                      if (turn.pending)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '已保存在本机 · 等待同步',
                            style: TextStyle(
                              fontSize: 10,
                              color: mobile ? Colors.white : p.muted,
                            ),
                          ),
                        ),
                    ],
                    if (c.generating) ...[
                      _bubble(c.sendingText, user: true, mobile: mobile),
                      _bubble(
                        c.partial.isEmpty ? '正在想怎么回答你…' : c.partial,
                        mobile: mobile,
                        streaming: true,
                      ),
                    ],
                  ],
                ),
        ),
        if (c.error.isNotEmpty)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: mobile ? 16 : 0,
              vertical: 4,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: p.glass,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(CupertinoIcons.info_circle, size: 14, color: p.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: p.ink),
                    ),
                  ),
                  if (c.draft.isNotEmpty && !c.generating)
                    TextButton(
                      onPressed: () => c.send(c.draft),
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
          ),
        if (!keyboard && turns.isEmpty && !c.generating) _suggestions(mobile),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: mobile ? 12 : 0),
          child: _composer(mobile),
        ),
        if (!mobile)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(
              children: [
                IconButton(
                  tooltip: '结束聊天',
                  onPressed: _endConversation,
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: const Size(24, 24),
                    padding: const EdgeInsets.all(3),
                  ),
                  icon: const Icon(CupertinoIcons.book, size: 12),
                ),
                Expanded(
                  child: Text(
                    c.settings.demo ? '离线演示 · 仅保存在本机' : c.syncStatus,
                    style: TextStyle(fontSize: 9, height: 1.15, color: p.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (c.account != null)
                  IconButton(
                    tooltip: '同步会话',
                    onPressed: c.generating ? null : c.sync,
                    icon: const Icon(
                      CupertinoIcons.arrow_2_circlepath,
                      size: 14,
                    ),
                  ),
                Text(
                  'AI 角色对话 · 请理性判断生成内容',
                  style: TextStyle(fontSize: 8, color: p.muted),
                ),
              ],
            ),
          ),
        if (mobile && c.settings.demo && keyboard)
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Text(
              '离线演示',
              style: TextStyle(fontSize: 9, color: Colors.white70),
            ),
          ),
      ],
    );
  }

  Widget _welcome({required bool mobile, required bool short}) {
    final p = RoomStyle(context);
    final shadows = mobile
        ? const [Shadow(color: Color(0xff18132a), blurRadius: 8)]
        : null;
    return LayoutBuilder(
      builder: (context, box) => Align(
        alignment: mobile ? Alignment.bottomCenter : const Alignment(0, .2),
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, mobile ? 26 : 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!mobile) ...[
                  Icon(CupertinoIcons.chat_bubble, size: 24, color: p.accent),
                  const SizedBox(height: 18),
                ],
                Text(
                  '这一刻，慢慢聊',
                  style: TextStyle(
                    fontFamily: RoomStyle.serif,
                    fontSize: 22,
                    fontWeight: FontWeight.w500,
                    letterSpacing: mobile ? 1 : 2,
                    color: mobile ? const Color(0xfff5f1fa) : p.ink,
                    shadows: shadows,
                  ),
                ),
                if (!short) ...[
                  const SizedBox(height: 12),
                  Text(
                    '今天的小事、想说的话，都可以留在这里。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.8,
                      color: mobile ? const Color(0xfff5f1fa) : p.muted,
                      shadows: shadows,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: () {
                    _input.text = '先和我打个招呼吧';
                    _send();
                  },
                  style: OutlinedButton.styleFrom(
                    backgroundColor: mobile ? p.glass : p.surface,
                    side: BorderSide(color: p.line),
                    minimumSize: Size(0, mobile ? 44 : 30),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    foregroundColor: p.ink,
                  ),
                  icon: const Icon(CupertinoIcons.sparkles, size: 15),
                  label: Text(
                    '我先说',
                    style: TextStyle(fontSize: mobile ? 13 : 10),
                  ),
                ),
                if (!mobile && box.maxHeight > 370) ...[
                  SizedBox(height: box.maxHeight * .19),
                  Text(
                    c.settings.demo
                        ? '离线演示 · ${_ready ? 'Live2D 已就绪' : '角色预览'}'
                        : _ready
                        ? 'Live2D 已就绪'
                        : '角色预览',
                    style: TextStyle(fontSize: 10, color: p.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _suggestions(bool mobile) {
    final p = RoomStyle(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        mobile ? 12 : 0,
        0,
        mobile ? 12 : 0,
        mobile ? 10 : 12,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final text in ['今天过得怎么样？', '想和你聊聊天', '给我一点鼓励'])
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: OutlinedButton(
                  onPressed: () {
                    _input.text = text;
                    _focus.requestFocus();
                  },
                  style: OutlinedButton.styleFrom(
                    backgroundColor: mobile ? p.glass : Colors.transparent,
                    foregroundColor: p.muted,
                    side: BorderSide(color: p.line),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    minimumSize: Size(0, mobile ? 36 : 28),
                  ),
                  child: Text(
                    text,
                    style: TextStyle(fontSize: mobile ? 11 : 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _composer(bool mobile) {
    final p = RoomStyle(context);
    final composing = _input.value.composing;
    final isComposing = composing.isValid && !composing.isCollapsed;
    final input = Shortcuts(
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
          onChanged: (value) => c.saveComposerDraft(value),
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
            hintText: mobile && c.settings.demo
                ? '离线演示 · 和八千代聊聊…'
                : '和八千代说点什么…',
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
      message: '图片聊天尚未接入',
      child: IconButton(
        onPressed: null,
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
            ? c.stop
            : (!c.canSend || _input.text.trim().isEmpty ? null : _send),
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
    return Container(
      key: const Key('room-composer'),
      padding: mobile
          ? const EdgeInsets.all(6)
          : const EdgeInsets.fromLTRB(10, 12, 10, 9),
      decoration: BoxDecoration(
        color: mobile ? p.glass : Colors.transparent,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(mobile ? 30 : 14),
      ),
      child: mobile
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                attach,
                Expanded(child: input),
                send,
              ],
            )
          : Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: input,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    attach,
                    Expanded(
                      child: Text(
                        'Enter 发送 · Shift + Enter 换行',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 8, color: p.muted),
                      ),
                    ),
                    const SizedBox(width: 10),
                    send,
                  ],
                ),
              ],
            ),
    );
  }

  Widget _bubble(
    String text, {
    bool user = false,
    bool mobile = false,
    bool streaming = false,
    DateTime? time,
  }) {
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
                const CharacterAvatar(size: 20, radius: 10),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: user
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!user)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
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
                                child: Text(
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
                        color: user
                            ? Color.alphaBlend(
                                p.accent.withValues(alpha: .12),
                                mobile ? p.glass : p.surface,
                              )
                            : mobile
                            ? p.glass
                            : p.soft,
                        border: Border.all(
                          color: p.line.withValues(alpha: .65),
                        ),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(user ? 20 : 4),
                          topRight: Radius.circular(user ? 4 : 20),
                          bottomLeft: const Radius.circular(20),
                          bottomRight: const Radius.circular(20),
                        ),
                      ),
                      child: SelectableText(
                        text,
                        style: TextStyle(
                          fontSize: mobile ? 14 : 13,
                          height: 1.8,
                          color: user ? p.accent : p.ink,
                        ),
                      ),
                    ),
                    if (!streaming)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (time != null)
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                              style: TextStyle(
                                fontSize: 9,
                                color: mobile ? Colors.white70 : p.muted,
                              ),
                            ),
                          if (!user) ...[
                            IconButton(
                              tooltip: '复制回复',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: text));
                                _notice('已复制回复');
                              },
                              style: IconButton.styleFrom(
                                minimumSize: Size(32, mobile ? 36 : 26),
                                padding: const EdgeInsets.all(4),
                              ),
                              icon: Icon(
                                CupertinoIcons.doc_on_doc,
                                size: 12,
                                color: mobile ? Colors.white : p.muted,
                              ),
                            ),
                            IconButton(
                              tooltip: c.voice.playing ? '停止语音' : '朗读回复',
                              onPressed: () => c.voice.playing
                                  ? c.voice.stop()
                                  : c.replay(text),
                              style: IconButton.styleFrom(
                                minimumSize: Size(32, mobile ? 36 : 26),
                                padding: const EdgeInsets.all(4),
                              ),
                              icon: Icon(
                                c.voice.playing
                                    ? CupertinoIcons.stop
                                    : CupertinoIcons.speaker_2,
                                size: 13,
                                color: mobile ? Colors.white : p.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
              if (user && !mobile) ...[
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 10,
                  backgroundColor: p.soft,
                  child: Text(
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

  void _history() => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: SizedBox(
        width: 580,
        height: MediaQuery.sizeOf(context).height * .75,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('对话历史', style: TextStyle(fontSize: 20)),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(CupertinoIcons.xmark),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final turn in c.turns) ...[
                      _bubble(turn.user, user: true, time: turn.createdAt),
                      _bubble(turn.assistant, time: turn.createdAt),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  void _search() {
    var query = '';
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => Dialog(
          child: SizedBox(
            width: 580,
            height: math.min(520, MediaQuery.sizeOf(context).height * .7),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '搜索月读空间',
                      hintText: '搜索本机对话',
                      prefixIcon: Icon(CupertinoIcons.search),
                    ),
                    onChanged: (v) => update(() => query = v.trim()),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView(
                      children: [
                        if (query.isEmpty)
                          const ListTile(title: Text('输入关键词，查找已保存的对话。')),
                        for (final turn in c.turns.where(
                          (t) =>
                              query.isNotEmpty &&
                              '${t.user}\n${t.assistant}'
                                  .toLowerCase()
                                  .contains(query.toLowerCase()),
                        ))
                          ListTile(
                            title: Text(
                              turn.user,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              turn.assistant,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _history();
                            },
                          ),
                        if (query.isNotEmpty &&
                            !c.turns.any(
                              (t) => '${t.user}\n${t.assistant}'
                                  .toLowerCase()
                                  .contains(query.toLowerCase()),
                            ))
                          const ListTile(title: Text('没有找到相关对话')),
                      ],
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
