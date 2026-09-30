import 'dart:ui' show AppExitResponse;

import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../../core/models.dart';
import '../../core/room_files.dart';
import '../../core/room_reply.dart';
import '../settings/room_memory_manager.dart';
import 'room_actions.dart';
import 'room_music.dart';
import 'room_navigation.dart';
import 'room_search.dart';
import '../../live2d/character_stage.dart';
import '../settings/settings_dialog.dart';
import '../site/login_dialog.dart';
import '../site/native_rich_text.dart';
import '../site/site_navigation.dart';
import 'room_controller.dart';
import 'room_panels.dart';
import 'room_style.dart';
import 'room_quick_setup.dart';
import '../agent/agent_panel.dart';
import '../agent/desktop_agent_controller.dart';

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
  final _conversationCenter = GlobalKey();
  DateTime _openedAt = DateTime.now();
  final _historicalIds = <String>{};
  late final RoomMusic _roomMusic;
  late final bool _ownsMusic;
  String _musicState = '';
  String _lastScope = '', _lastDraft = '', _panel = '聊天';
  bool _ready = false, _quiet = false;
  final _unread = ValueNotifier<bool>(false);
  DesktopAgentController? _agent;
  Map<String, IconData> get _roomTabs => {
    ..._tabs,
    if (desktopAgentSupported) 'Agent': Icons.auto_awesome,
  };
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
    _historicalIds.addAll(c.visibleTurns.map((t) => t.id));
    _lastDraft = c.draft;
    _input.text = c.draft;
    c.addListener(_update);
    c.streamRevision.addListener(_followConversation);
    final shared = SiteMusicScope.maybeOf(context);
    _ownsMusic = shared == null;
    _roomMusic = (shared ?? RoomMusic(c))..addListener(_musicChanged);
    if (_ownsMusic) {
      c.registerBackgroundMusic(this, _roomMusic.suspend);
      unawaited(_roomMusic.load());
    }
  }

  void _musicChanged() {
    final state =
        '${_roomMusic.index}/${_roomMusic.playing}/${_roomMusic.loading}/${_roomMusic.error}';
    if (mounted && state != _musicState) {
      setState(() => _musicState = state);
    }
  }

  void _followConversation() {
    if (!mounted || !_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 100) {
      _unread.value = true;
      return;
    }
    final pixels = _scroll.position.pixels;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _scroll.hasClients &&
          (_scroll.position.pixels - pixels).abs() < 1) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_update);
    c.streamRevision.removeListener(_followConversation);
    _unread.dispose();
    _agent?.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    _roomMusic.removeListener(_musicChanged);
    if (_ownsMusic) {
      c.unregisterBackgroundMusic(this);
      _roomMusic.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.resume();
    } else if (state == AppLifecycleState.detached) {
      unawaited(_agent?.shutdown().catchError((Object _) {}));
      c.pause();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      c.pause();
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      await _agent?.shutdown();
    } catch (_) {
      // Exiting must still proceed if the local history cannot be saved.
    }
    return AppExitResponse.exit;
  }

  void _update() {
    if (!mounted) return;
    if (_lastScope != c.scope) {
      _openedAt = DateTime.now();
      _historicalIds
        ..clear()
        ..addAll(c.visibleTurns.map((t) => t.id));
      _unread.value = false;
    }
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
    if (!nearBottom && (c.visibleTurns.isNotEmpty || c.generating)) {
      _unread.value = true;
    }
    if (nearBottom && (c.visibleTurns.isNotEmpty || c.generating)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  void _send() {
    if ((_input.text.trim().isEmpty && c.attachment == null) || !c.canSend) {
      return;
    }
    final value = _input.text;
    // Keep rejected oversized input visible, matching controller validation.
    if (value.trim().length > 12000) {
      unawaited(c.send(value));
      return;
    }
    _input.clear();
    unawaited(c.send(value));
  }

  void _settings() =>
      unawaited(showRoomSettings(context, c, onTheme: widget.onToggleTheme));
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
    if (path == '/room') {
      _selectPanel('聊天');
      return;
    }
    if (widget.onNavigate != null) {
      widget.onNavigate!(path);
    } else {
      await navigateSite(context, c, path);
    }
  }

  Future<void> _newConversation() async {
    try {
      if (!c.canSend) return;
      if (!await roomConfirm(
        context,
        '开启新的对话？',
        '这会清空当前聊天和未生成日记的录制，已保存的日记与长期记忆会保留。',
      )) {
        return;
      }
      await c.startConversation(clearHistory: true);
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

  void _endConversation() =>
      unawaited(endRoomConversation(context, c, () => _selectPanel('日记')));
  void _music() {
    unawaited(showRoomMusic(context, _roomMusic));
  }

  void _selectPanel(String panel) {
    if (panel == 'Agent' && _agent == null) {
      _agent = DesktopAgentController(c);
      unawaited(_agent!.restore());
    }
    setState(() {
      _panel = panel;
      _quiet = false;
    });
  }

  Future<void> _attach() async {
    final scope = c.scope;
    try {
      final image = await pickRoomImage();
      if (image != null && scope == c.scope) await c.attach(image);
    } catch (e) {
      if (mounted) _notice(e is ApiFailure ? e.message : '图片读取失败，请重新选择');
    }
  }

  Widget _image(Map<String, dynamic> image, {double height = 160}) {
    final data = '${image['dataUrl'] ?? ''}', url = '${image['url'] ?? ''}';
    Widget error(BuildContext context, Object error, StackTrace? stack) =>
        const SiteText('图片暂不可用');
    try {
      final origin = endpointUri(c.settings.siteUrl);
      final remote = origin.resolve(url);
      if (!data.startsWith('data:image/') &&
          !['https', 'http'].contains(remote.scheme)) {
        return const SiteText('图片地址不可用');
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: data.startsWith('data:image/')
            ? Image.memory(
                base64Decode(data.split(',').last),
                height: height,
                cacheHeight: (height * MediaQuery.devicePixelRatioOf(context))
                    .ceil(),
                fit: BoxFit.contain,
                errorBuilder: error,
              )
            : Image.network(
                remote.toString(),
                headers: c.site.cookie == null || remote.origin != origin.origin
                    ? null
                    : {'Cookie': c.site.cookie!},
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
              final headerHeight = math.max(
                mobile ? 60.0 : 68.0,
                MediaQuery.textScalerOf(context).scale(21) * 1.2 +
                    MediaQuery.textScalerOf(context).scale(10) * 1.2 +
                    24,
              );
              final landscape = mobile && box.maxHeight < 500 && keyboard == 0;
              final stage = CharacterStage(
                key: _stageKey,
                voice: c.voice,
                settings: c.settings,
                animation: c.animation,
                world: c.workspace.currentWorld,
                onWorld: () => unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const SiteText('房间环境'),
                      content: AnimatedBuilder(
                        animation: c.workspace,
                        builder: (context, _) => Text(
                          '${c.workspace.currentWorld["city"] ?? "月读空间"}  ${c.workspace.currentWorld["temperature"] ?? ""}°\n${c.workspace.worldStatus}',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => c.workspace.refreshWorld(),
                          child: const SiteText('刷新'),
                        ),
                        TextButton(
                          onPressed: () =>
                              c.workspace.refreshWorld(locate: true),
                          child: const SiteText('使用当前位置'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const SiteText('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
                loadNative: widget.loadNative,
                modelLoader: widget.modelLoader,
                mobile: mobile,
                keyboardOpen: keyboard > 0,
                onSettings: _settings,
                onVoiceSettings: () => showRoomSettings(
                  context,
                  c,
                  section: 'tts',
                  onTheme: widget.onToggleTheme,
                ),
                onMusic: _music,
                musicTitle: '${_roomMusic.tracks[_roomMusic.index]['title']}',
                musicPlaying: _roomMusic.playing,
                musicLoading: _roomMusic.loading,
                onMusicToggle: () async {
                  await _roomMusic.toggle();
                  if (mounted && _roomMusic.error.isNotEmpty) {
                    _notice(_roomMusic.error);
                  }
                },
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
                      top: math.max(104, headerHeight + 36),
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
                    Positioned(
                      top: headerHeight + 22,
                      left: 16,
                      child: _mobileTools(),
                    ),
                    Positioned(
                      top: headerHeight + 22,
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
                    height: headerHeight,
                    child: RoomNavigation(
                      mobile: mobile,
                      width: box.maxWidth,
                      onGo: (path) =>
                          path == '/room' ? _selectPanel('聊天') : _website(path),
                      onSearch: _search,
                      onSettings: _settings,
                      onTheme: widget.onToggleTheme,
                      onAccount: c.loading || c.busy || c.generating
                          ? null
                          : _account,
                      accountLabel: c.sessionExpired
                          ? '重新登录'
                          : c.account?.displayName ?? '登录',
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

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
        tooltip: siteTranslate(context, '房间功能'),
        offset: const Offset(0, 54),
        icon: const Icon(CupertinoIcons.chat_bubble, size: 23),
        onSelected: (v) {
          if (_roomTabs.containsKey(v)) {
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
          const PopupMenuItem<String>(
            enabled: false,
            child: SiteText('这一刻，慢慢聊'),
          ),
          PopupMenuItem(
            value: 'new',
            enabled: c.canSend,
            child: const SiteText('新建会话'),
          ),
          const PopupMenuItem(value: 'history', child: SiteText('查看对话开头')),
          for (final e in _roomTabs.entries)
            PopupMenuItem(
              value: e.key,
              child: Row(
                children: [
                  Icon(e.value, size: 18),
                  const SizedBox(width: 12),
                  SiteText(e.key),
                ],
              ),
            ),
          const PopupMenuItem(value: 'music', child: SiteText('房间音乐')),
          PopupMenuItem(value: 'quiet', child: Text(_quiet ? '返回聊天' : '安静陪伴')),
          const PopupMenuItem(value: 'end', child: SiteText('结束聊天')),
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
                    SiteText(
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
                tooltip: siteTranslate(context, '查看对话历史'),
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
                label: const SiteText('新建会话', style: TextStyle(fontSize: 10)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: math.max(
              43,
              MediaQuery.textScalerOf(context).scale(12) * 1.5 + 16,
            ),
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
                        for (final e in _roomTabs.entries)
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
                                label: SiteText(
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
                  tooltip: siteTranslate(context, '房间设置'),
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

  Widget _utilityPanel() => _panel == 'Agent'
      ? AgentPanel(controller: _agent!, onGo: (path) => _website(path))
      : RoomUtilityPanel(
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
              SiteText(_panel, style: const TextStyle(fontSize: 18)),
              const Spacer(),
              IconButton(
                tooltip: siteTranslate(context, '返回聊天'),
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
          child:
              !c.loading && !c.settings.demo && c.settings.model.trim().isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: RoomQuickSetup(controller: c),
                )
              : c.loading && turns.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : turns.isEmpty && !c.generating
              ? _welcome(mobile: mobile, short: short || keyboard)
              : _messageList(turns, mobile: mobile),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _unread,
          builder: (context, unread, _) => unread
              ? TextButton.icon(
                  icon: const Icon(Icons.arrow_downward, size: 16),
                  label: const SiteText('查看新消息'),
                  onPressed: () {
                    _unread.value = false;
                    if (_scroll.hasClients) {
                      _scroll.jumpTo(_scroll.position.maxScrollExtent);
                    }
                  },
                )
              : const SizedBox.shrink(),
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
                  if ((c.draft.isNotEmpty || c.attachment != null) &&
                      !c.generating)
                    TextButton(
                      onPressed: () => c.send(c.draft),
                      child: const SiteText('重试'),
                    ),
                ],
              ),
            ),
          ),
        if (!keyboard &&
            turns.isEmpty &&
            !c.generating &&
            (c.settings.demo || c.settings.model.isNotEmpty))
          _suggestions(mobile),
        if (c.attachment != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _image(c.attachment!, height: 64),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${c.attachment!['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: siteTranslate(context, '移除图片'),
                  onPressed: c.canSend ? () => c.attach(null) : null,
                  icon: const Icon(CupertinoIcons.xmark),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: mobile ? 12 : 0),
          child: AnimatedBuilder(
            animation: _input,
            builder: (context, _) => _composer(mobile),
          ),
        ),
        if (!mobile)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(
              children: [
                IconButton(
                  tooltip: siteTranslate(context, '结束聊天'),
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
                    tooltip: siteTranslate(context, '同步会话'),
                    onPressed: c.generating ? null : c.sync,
                    icon: const Icon(
                      CupertinoIcons.arrow_2_circlepath,
                      size: 14,
                    ),
                  ),
                Flexible(
                  child: SiteText(
                    'AI 角色对话 · 请理性判断生成内容',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 8, color: p.muted),
                  ),
                ),
              ],
            ),
          ),
        if (mobile && c.settings.demo && keyboard)
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: SiteText(
              '离线演示',
              style: TextStyle(fontSize: 9, color: Colors.white70),
            ),
          ),
      ],
    );
  }

  Widget _messageList(List<ChatTurn> turns, {required bool mobile}) {
    // History grows upwards from a fixed centre. New replies grow downwards,
    // keeping the same pixel offset while the user reads older messages.
    final history = <ChatTurn>[], recent = <ChatTurn>[];
    for (final turn in turns) {
      if (_historicalIds.contains(turn.id) ||
          !turn.createdAt.isAfter(_openedAt)) {
        history.add(turn);
      } else {
        recent.add(turn);
      }
    }
    final historyIndices = {
      for (var i = 0; i < history.length; i++)
        history[i].id: history.length - 1 - i,
    };
    final recentIndices = {
      for (var i = 0; i < recent.length; i++) recent[i].id: i,
    };
    final shared = c.sharedConversation;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 16 && _unread.value) {
          _unread.value = false;
        }
        return false;
      },
      child: CustomScrollView(
        key: ValueKey('conversation:${c.scope}'),
        controller: _scroll,
        center: _conversationCenter,
        anchor: 1,
        scrollCacheExtent: const ScrollCacheExtent.pixels(240),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: mobile ? 16 : 1),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index == history.length) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Text(shared?['title']?.toString() ?? '公开对话片段'),
                    );
                  }
                  final turn = history[history.length - 1 - index];
                  return _turnItem(
                    turn,
                    mobile: mobile,
                    last: turn.id == turns.last.id,
                  );
                },
                childCount: history.length + (shared == null ? 0 : 1),
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? historyIndices[key.value] : null,
              ),
            ),
          ),
          SliverPadding(
            key: _conversationCenter,
            padding: EdgeInsets.fromLTRB(
              mobile ? 16 : 1,
              0,
              mobile ? 16 : 1,
              6,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index < recent.length) {
                    final turn = recent[index];
                    return _turnItem(
                      turn,
                      mobile: mobile,
                      last: turn.id == turns.last.id,
                    );
                  }
                  return AnimatedBuilder(
                    key: const ValueKey('streaming-reply'),
                    animation: c.streamRevision,
                    builder: (context, _) => Column(
                      children: [
                        _bubble(c.sendingText, user: true, mobile: mobile),
                        _replyBubbles(
                          cleanRoomReply(c.partial).isEmpty
                              ? '正在想怎么回答你…'
                              : cleanRoomReply(c.partial),
                          mobile: mobile,
                          streaming: true,
                        ),
                      ],
                    ),
                  );
                },
                childCount: recent.length + (c.generating ? 1 : 0),
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? recentIndices[key.value] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _turnItem(ChatTurn turn, {required bool mobile, required bool last}) {
    final p = RoomStyle(context);
    return RepaintBoundary(
      key: ValueKey(turn.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (turn.image != null)
            Align(alignment: Alignment.centerRight, child: _image(turn.image!)),
          if (turn.user.isNotEmpty)
            _bubble(
              turn.user,
              user: true,
              mobile: mobile,
              time: turn.createdAt,
            ),
          _replyBubbles(turn.assistant, mobile: mobile, time: turn.createdAt),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              if (!c.isSharedTurn(turn) &&
                  !turn.pending &&
                  turn.image == null &&
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
                  turn.image == null)
                TextButton(
                  onPressed: c.canSend
                      ? () => shareRoomTurn(context, c, turn)
                      : null,
                  child: const SiteText('分享'),
                ),
            ],
          ),
          if (turn.pending)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SiteText(
                '已保存在本机 · 等待同步',
                style: TextStyle(
                  fontSize: 10,
                  color: mobile ? Colors.white : p.muted,
                ),
              ),
            ),
        ],
      ),
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
                SiteText(
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
                  SiteText(
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
                  onPressed: c.canSend ? () => c.send('', opener: true) : null,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: mobile ? p.glass : p.surface,
                    side: BorderSide(color: p.line),
                    minimumSize: Size(0, mobile ? 44 : 30),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    foregroundColor: p.ink,
                  ),
                  icon: const Icon(CupertinoIcons.sparkles, size: 15),
                  label: SiteText(
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
        onPressed: c.canSend ? _attach : null,
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
            : (!c.canSend ||
                      (_input.text.trim().isEmpty && c.attachment == null)
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
                      child: SiteText(
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

  bool _hasMarkdown(String text) =>
      RegExp(r'(^|\n)\s*(#{1,6} |[-*] |[0-9]+\. |~~~)|\*\*|\[[^\]]+\]\(')
          .hasMatch(text) ||
      text.contains(String.fromCharCode(96) * 3);

  Widget _replyBubbles(
    String text, {
    required bool mobile,
    DateTime? time,
    bool streaming = false,
  }) {
    final parts = !streaming && _hasMarkdown(text)
        ? [text]
        : splitRoomReply(text);
    return Column(
      children: [
        for (var i = 0; i < parts.length; i++)
          _bubble(
            parts[i],
            mobile: mobile,
            time: time,
            streaming: streaming,
            continuation: i > 0,
            controls: i == parts.length - 1,
            fullReply: text,
          ),
      ],
    );
  }

  Widget _bubble(
    String text, {
    bool user = false,
    bool mobile = false,
    bool streaming = false,
    bool continuation = false,
    bool controls = true,
    String? fullReply,
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
                      child: !user && !streaming && _hasMarkdown(text)
                          ? NativeRichText(
                              content: text,
                              format: 'markdown',
                              site: c.settings.siteUrl,
                              onNavigate: (path) => _website(path),
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
                              tooltip: siteTranslate(context, '复制回复'),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: fullReply ?? text),
                                );
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
                                  : c.replay(fullReply ?? text),
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
                  const SiteText('对话历史', style: TextStyle(fontSize: 20)),
                  const Spacer(),
                  IconButton(
                    tooltip: siteTranslate(context, '关闭'),
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
  void _search() => unawaited(showRoomSearch(context, c, _website));
}
