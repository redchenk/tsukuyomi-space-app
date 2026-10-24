import 'dart:ui' show AppExitResponse;

import '../../core/site_localization.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../site/site_widgets.dart' show SiteBackground;

import 'package:flutter/services.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../../core/models.dart';
import '../../core/room_files.dart';
import '../settings/room_memory_manager.dart';
import 'room_actions.dart';
import 'room_music.dart';
import 'room_navigation.dart';
import 'room_search.dart';
import '../../live2d/character_stage.dart';
import '../settings/settings_dialog.dart';
import '../site/login_dialog.dart';
import '../site/site_navigation.dart';
import 'room_controller.dart';
import 'room_panels.dart';
import 'room_style.dart';
import 'room_quick_setup.dart';
import 'room_help.dart';
import 'room_message_cache.dart';
import 'room_chat_view.dart';
import 'room_composer.dart';
import 'room_interaction.dart';
import 'room_selector.dart';
import '../agent/agent_panel.dart';
import '../agent/desktop_agent_controller.dart';

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
  final _stageKey = GlobalKey();
  final _composerKey = GlobalKey<RoomComposerState>();
  final _messages = RoomMessageCache();
  final _interaction = RoomInteraction();
  final _ready = ValueNotifier<bool>(false);
  Object? _stageStamp;
  Widget? _stageWidget, _chatWidget, _conversationWidget, _navigationWidget;
  Object? _conversationStamp, _navigationStamp;
  bool? _chatMobile;
  late final RoomMusic _roomMusic;
  late final Listenable _sceneSources, _workspaceSources;
  late final bool _ownsMusic;
  String _panel = '聊天';
  String _imageScope = '';
  bool _quiet = false, _setupDismissed = false;
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
    final shared = SiteMusicScope.maybeOf(context);
    _ownsMusic = shared == null;
    _roomMusic = shared ?? RoomMusic(c);
    _sceneSources = Listenable.merge([c, _roomMusic]);
    _workspaceSources = Listenable.merge([c, _ready]);
    if (_ownsMusic) {
      c.registerBackgroundMusic(this, _roomMusic.suspend);
      unawaited(_roomMusic.load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ready.dispose();
    _interaction.dispose();
    _messages.clear();
    _agent?.dispose();
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

  @override
  void didChangeMetrics() {
    _interaction.keyboardTransition();
  }

  void _settings() =>
      unawaited(showRoomSettings(context, c, onTheme: widget.onToggleTheme));
  void _help() => unawaited(
    showRoomHelp(context, c, onGo: _website, onDiary: () => _selectPanel('日记')),
  );
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
                _messages.image(data),
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

  Widget _characterStage({required bool mobile, required bool keyboardOpen}) {
    if (_imageScope != c.scope) {
      _imageScope = c.scope;
      _messages.clear();
    }
    final stamp = (
      c.scope,
      c.settings,
      c.voice,
      c.animation,
      c.workspace.currentWorld['city'],
      widget.loadNative,
      widget.modelLoader,
      mobile,
      keyboardOpen,
      _roomMusic.index,
      _roomMusic.playing,
      _roomMusic.loading,
    );
    if (_stageStamp != stamp) {
      _stageStamp = stamp;
      _stageWidget = CharacterStage(
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
                  onPressed: () => c.workspace.refreshWorld(locate: true),
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
        keyboardOpen: keyboardOpen,
        interacting: _interaction,
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
          if (mounted) _ready.value = value;
        },
      );
    }
    return _stageWidget!;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _search,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _search,
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          maintainBottomViewPadding: true,
          child: LayoutBuilder(
            builder: (context, box) {
              final keyboard = MediaQuery.viewInsetsOf(context).bottom;
              final mobile = box.maxWidth <= RoomStyle.breakpoint;
              final headerHeight = math.max(
                mobile ? 60.0 : 68.0,
                MediaQuery.textScalerOf(context).scale(21) * 1.2 +
                    MediaQuery.textScalerOf(context).scale(10) * 1.2 +
                    24,
              );
              final landscape = mobile && box.maxHeight < 500 && keyboard == 0;
              final compactKeyboard =
                  mobile && keyboard > 0 && box.maxHeight - keyboard < 240;
              final stage = RoomSelector(
                listenable: _sceneSources,
                select: () => (
                  c.scope,
                  c.settings,
                  c.workspace.currentWorld['city'],
                  _roomMusic.index,
                  _roomMusic.playing,
                  _roomMusic.loading,
                ),
                builder: (_) =>
                    _characterStage(mobile: mobile, keyboardOpen: keyboard > 0),
              );
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (!mobile) ...[
                    const Positioned.fill(
                      child: SiteBackground(child: SizedBox.shrink()),
                    ),
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
                    if (!compactKeyboard)
                      Positioned(
                        top: headerHeight + 22,
                        left: 16,
                        child: RoomSelector(
                          listenable: c,
                          select: () => c.canSend,
                          builder: (_) => _mobileTools(),
                        ),
                      ),
                    if (!compactKeyboard)
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
                        top: compactKeyboard
                            ? 8
                            : keyboard > 0
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
                  if (!compactKeyboard && !(mobile && keyboard > 0))
                    Positioned(
                      top: mobile ? 10 : 16,
                      left: mobile
                          ? 12
                          : math.max(24, (box.maxWidth - 1320) / 2),
                      right: mobile
                          ? 12
                          : math.max(24, (box.maxWidth - 1320) / 2),
                      height: headerHeight,
                      child: _navigation(mobile, box.maxWidth),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _navigation(bool mobile, double width) {
    final stamp = (mobile, width, widget.onToggleTheme, widget.onNavigate);
    if (_navigationStamp != stamp) {
      _navigationStamp = stamp;
      _navigationWidget = RoomSelector(
        listenable: c,
        select: () => (
          c.loading,
          c.busy,
          c.generating,
          c.sessionExpired,
          c.account,
          c.sessionVerified,
        ),
        builder: (_) => RoomNavigation(
          mobile: mobile,
          width: width,
          onGo: (path) => path == '/room' ? _selectPanel('聊天') : _website(path),
          onSearch: _search,
          onSettings: _settings,
          onTheme: widget.onToggleTheme,
          onAccount: c.loading || c.busy || c.generating ? null : _account,
          accountLabel: c.sessionExpired
              ? '重新登录'
              : c.account?.displayName ?? '登录',
        ),
      );
    }
    return _navigationWidget!;
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
          } else if (v == 'help') {
            _help();
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
            value: 'help',
            child: SiteText('开始使用与发现功能'),
          ),
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

  Widget _desktopWorkspace() => RoomSelector(
    listenable: _workspaceSources,
    select: () =>
        (c.scope, c.canSend, c.generating, c.turns.isEmpty, _ready.value),
    builder: (_) => _desktopWorkspaceBody(),
  );

  Widget _desktopWorkspaceBody() {
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
                          color: _ready.value ? p.success : p.muted,
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
                  tooltip: siteTranslate(context, '开始使用与发现功能'),
                  onPressed: _help,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(30, 30),
                    padding: const EdgeInsets.all(4),
                  ),
                  icon: const Icon(CupertinoIcons.question_circle, size: 18),
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

  Widget _utilityPanel() => RoomSelector(
    listenable: c,
    select: () => c.scope,
    builder: (_) => _utilityPanelBody(),
  );

  Widget _utilityPanelBody() => _panel == 'Agent'
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
    final stamp = (mobile, keyboard, short, _setupDismissed, Theme.of(context));
    if (_conversationStamp != stamp) {
      _conversationStamp = stamp;
      _conversationWidget = RoomSelector(
        listenable: c,
        select: () => (
          c.scope,
          c.loading,
          c.settings.demo,
          c.settings.model,
          c.visibleTurns.isEmpty,
          c.generating,
          c.error,
          c.draft.isNotEmpty,
          c.attachment,
          c.canSend,
        ),
        builder: (_) =>
            _conversationBody(mobile: mobile, keyboard: keyboard, short: short),
      );
    }
    return _conversationWidget!;
  }

  Widget _conversationBody({
    required bool mobile,
    required bool keyboard,
    required bool short,
  }) {
    final turns = c.visibleTurns;
    final p = RoomStyle(context);
    final needsSetup =
        !c.loading && !c.settings.demo && c.settings.model.trim().isEmpty;
    return Column(
      children: [
        if (needsSetup && (_setupDismissed || turns.isNotEmpty))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                backgroundColor: p.glass,
                foregroundColor: p.ink,
              ),
              onPressed: () => showRoomSettings(context, c, guidedSetup: true),
              icon: const Icon(Icons.tune, size: 18),
              label: const SiteText('配置聊天模型'),
            ),
          ),
        Expanded(
          child: needsSetup && !_setupDismissed && turns.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: RoomQuickSetup(
                    controller: c,
                    onDiscover: _help,
                    onDismiss: () => setState(() => _setupDismissed = true),
                  ),
                )
              : c.loading && turns.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : turns.isEmpty && !c.generating
              ? _welcome(mobile: mobile, short: short || keyboard)
              : _chat(mobile),
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
          key: const ValueKey('room-composer-slot'),
          padding: EdgeInsets.symmetric(horizontal: mobile ? 12 : 0),
          child: RoomComposer(
            key: _composerKey,
            controller: c,
            mobile: mobile,
            onAttach: () => unawaited(_attach()),
            onTyping: _interaction.typing,
          ),
        ),
        if (!mobile)
          RoomSelector(
            listenable: c,
            select: () =>
                (c.settings.demo, c.syncStatus, c.account, c.generating),
            builder: (_) => Padding(
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
                      style: TextStyle(
                        fontSize: 9,
                        height: 1.15,
                        color: p.muted,
                      ),
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

  Widget _chat(bool mobile) {
    if (_chatWidget == null || _chatMobile != mobile) {
      _chatMobile = mobile;
      _chatWidget = RoomChatView(
        controller: c,
        mobile: mobile,
        onNavigate: _website,
        onNotice: _notice,
        onScrollActivity: _interaction.scrolling,
      );
    }
    return _chatWidget!;
  }

  Widget _welcome({required bool mobile, required bool short}) => RoomSelector(
    listenable: _workspaceSources,
    select: () => (c.canSend, c.settings.demo, _ready.value),
    builder: (_) => _welcomeBody(mobile: mobile, short: short),
  );

  Widget _welcomeBody({required bool mobile, required bool short}) {
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
                TextButton(
                  onPressed: _help,
                  child: const SiteText('第一次使用 / 发现功能'),
                ),
                if (!mobile && box.maxHeight > 370) ...[
                  SizedBox(height: box.maxHeight * .19),
                  Text(
                    c.settings.demo
                        ? '离线演示 · ${_ready.value ? 'Live2D 已就绪' : '角色预览'}'
                        : _ready.value
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
                    _composerKey.currentState?.fillDraft(text);
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
                child: RoomChatHistoryView(
                  controller: c,
                  mobile:
                      MediaQuery.sizeOf(context).width <= RoomStyle.breakpoint,
                  onNavigate: _website,
                  onNotice: _notice,
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
