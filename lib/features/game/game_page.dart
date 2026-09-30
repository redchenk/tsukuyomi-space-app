import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/site_localization.dart';
import '../../core/models.dart';
import '../room/room_controller.dart';
import '../room/room_style.dart';
import '../site/login_dialog.dart';
import '../site/site_chrome.dart';
import '../site/site_widgets.dart';
import 'game_session.dart';
import 'kaguya_assets.dart';
import 'kaguya_audio.dart';
import 'kaguya_runtime.dart';

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.controller,
    this.path = '/game',
    required this.onGo,
    this.onTheme,
  });
  final RoomController controller;
  final String path;
  final ValueChanged<String> onGo;
  final VoidCallback? onTheme;
  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final GameSession session;
  late final Ticker _ticker;
  final _focus = FocusNode();
  KaguyaAssets? _assets;
  KaguyaRuntime? _runtime;
  KaguyaAudio? _audio;
  Duration _elapsed = Duration.zero;
  String _loadError = '';
  bool _loading = true, _expanded = false, _backgroundPause = false;
  int _loadTicket = 0, _volumeTick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session = GameSession(widget.controller)..addListener(_sessionChanged);
    _ticker = createTicker(_tick)..start();
    unawaited(widget.controller.suspendBackgroundMusic());
    unawaited(session.initialize());
    unawaited(_load());
  }

  void _sessionChanged() {
    _audio?.configure(gain: session.volume, mute: session.muted);
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final ticket = ++_loadTicket;
    setState(() {
      _loading = true;
      _loadError = '';
    });
    try {
      final assets = await KaguyaAssets.load();
      if (!mounted || ticket != _loadTicket) {
        assets.dispose();
        return;
      }
      _audio?.dispose();
      _runtime?.dispose();
      _assets?.dispose();
      _assets = assets;
      _runtime = assets.runtime();
      _audio = KaguyaAudio(_runtime!)
        ..configure(gain: session.volume, mute: session.muted);
      _runtime!.greenFlag();
      _runtime!.paused = _backgroundPause;
      _audio!.pause(_backgroundPause);
      setState(() => _loading = false);
    } catch (_) {
      if (mounted && ticket == _loadTicket) {
        setState(() {
          _loading = false;
          _loadError = '游戏素材加载失败，请重试';
        });
      }
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _elapsed).inMicroseconds / 1000000;
    _elapsed = elapsed;
    final runtime = _runtime;
    if (runtime == null || dt <= 0 || runtime.paused) return;
    runtime.advance(dt);
    session.updateScore(runtime.score);
    if (++_volumeTick % 15 == 0) _audio?.syncVolumes();
  }

  void _pause() {
    final runtime = _runtime;
    if (runtime == null) return;
    runtime.togglePause();
    runtime.keys.clear();
    runtime.mouseDown = false;
    _audio?.pause(runtime.paused);
    if (runtime.paused) unawaited(session.flushScore());
    setState(() {});
  }

  void _restart() {
    unawaited(session.flushScore());
    _runtime?.restart();
    _audio?.pause(false);
    _focus.requestFocus();
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final runtime = _runtime;
    if (state != AppLifecycleState.resumed &&
        runtime != null &&
        !runtime.paused) {
      _backgroundPause = true;
      runtime.paused = true;
      runtime.keys.clear();
      runtime.mouseDown = false;
      _audio?.pause(true);
      unawaited(session.flushScore());
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      // Keep the game paused until the player resumes deliberately.
      _backgroundPause = false;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is! KeyUpEvent;
    if (down &&
        event is KeyDownEvent &&
        (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.keyP)) {
      if (_expanded && key == LogicalKeyboardKey.escape) {
        setState(() => _expanded = false);
      } else {
        _pause();
      }
      return KeyEventResult.handled;
    }
    final scratch = switch (key) {
      LogicalKeyboardKey.arrowUp => 'up arrow',
      LogicalKeyboardKey.arrowDown => 'down arrow',
      LogicalKeyboardKey.arrowLeft => 'left arrow',
      LogicalKeyboardKey.arrowRight => 'right arrow',
      LogicalKeyboardKey.space => 'space',
      _ => key.keyLabel.toLowerCase(),
    };
    _runtime?.key(scratch, down);
    return [
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ].contains(key)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  Future<void> _login() async {
    await showSiteLogin(context, widget.controller);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final style = RoomStyle(context);
    return Scaffold(
      backgroundColor: style.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            if (_expanded) {
              return Column(
                children: [
                  _toolbar(),
                  Expanded(
                    child: Center(
                      child: _stage(
                        math.min(box.maxWidth, (box.maxHeight - 60) * 4 / 3),
                      ),
                    ),
                  ),
                ],
              );
            }
            return SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1260),
                  child: Padding(
                    padding: EdgeInsets.all(box.maxWidth < 600 ? 8 : 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SiteHeader(
                          title: '辉夜快跑',
                          onGo: widget.onGo,
                          onLogin: _login,
                          onTheme: widget.onTheme,
                          username: widget.controller.sessionExpired
                              ? null
                              : widget.controller.account?.displayName,
                          role: widget.controller.sessionExpired
                              ? null
                              : widget.controller.account?.role,
                        ),
                        const SizedBox(height: 20),
                        SiteText(
                          '辉夜快跑',
                          style: TextStyle(
                            fontSize: 30,
                            fontFamily: RoomStyle.serif,
                            color: style.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SiteText(
                          '空格跳跃 · ↑ ↓ 控制 · 点击画面中的「开始游戏」',
                          style: TextStyle(color: style.muted),
                        ),
                        const SizedBox(height: 12),
                        _toolbar(),
                        const SizedBox(height: 8),
                        Center(
                          child: _stage(
                            math.min(
                              box.maxWidth - (box.maxWidth < 600 ? 16 : 48),
                              960,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => launchUrl(
                              Uri.parse(
                                'https://www.bilibili.com/video/BV1Bmgx6aEvJ/',
                              ),
                              mode: LaunchMode.externalApplication,
                            ),
                            icon: const Icon(Icons.open_in_new, size: 15),
                            label: const SiteText('原作者'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _leaderboard(),
                        const SizedBox(height: 24),
                        const SiteBeianFooter(path: '/game'),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _toolbar() => Wrap(
    spacing: 6,
    runSpacing: 4,
    alignment: WrapAlignment.center,
    children: [
      OutlinedButton.icon(
        onPressed: _runtime == null ? null : _pause,
        icon: Icon(_runtime?.paused == true ? Icons.play_arrow : Icons.pause),
        label: SiteText(_runtime?.paused == true ? '继续' : '暂停'),
      ),
      OutlinedButton.icon(
        onPressed: _runtime == null ? null : _restart,
        icon: const Icon(Icons.replay),
        label: const SiteText('重开'),
      ),
      OutlinedButton.icon(
        onPressed: () => setState(() => _expanded = !_expanded),
        icon: Icon(_expanded ? Icons.fullscreen_exit : Icons.fullscreen),
        label: SiteText(_expanded ? '退出全屏' : '全屏'),
      ),
      IconButton(
        tooltip: session.muted ? '开启声音' : '静音',
        onPressed: () => session.configure(mute: !session.muted),
        icon: Icon(session.muted ? Icons.volume_off : Icons.volume_up),
      ),
      OutlinedButton.icon(
        onPressed: _settings,
        icon: const Icon(Icons.tune),
        label: const SiteText('设置'),
      ),
    ],
  );
  Widget _stage(double width) {
    final runtime = _runtime;
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ColoredBox(
            color: Colors.black,
            child: _loading
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        SiteText(
                          '正在加载原版游戏素材',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  )
                : _loadError.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _loadError,
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextButton(
                          onPressed: _load,
                          child: const SiteText('重试'),
                        ),
                      ],
                    ),
                  )
                : runtime == null
                ? const SizedBox.shrink()
                : Focus(
                    focusNode: _focus,
                    onKeyEvent: _key,
                    onFocusChange: (focused) {
                      if (!focused) runtime.keys.clear();
                    },
                    child: LayoutBuilder(
                      builder: (context, bounds) => Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) {
                          _focus.requestFocus();
                          runtime.click(
                            e.localPosition.dx / bounds.maxWidth * 480 - 240,
                            180 - e.localPosition.dy / bounds.maxHeight * 360,
                          );
                        },
                        onPointerMove: (e) {
                          runtime.mouseX =
                              e.localPosition.dx / bounds.maxWidth * 480 - 240;
                          runtime.mouseY =
                              180 - e.localPosition.dy / bounds.maxHeight * 360;
                        },
                        onPointerUp: (_) => runtime.mouseDown = false,
                        onPointerCancel: (_) => runtime.mouseDown = false,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              painter: KaguyaPainter(runtime, _assets!),
                            ),
                            if (session.touchControls && !runtime.paused)
                              Positioned(
                                left: 12,
                                right: 12,
                                bottom: 10,
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    _touch(
                                      'space',
                                      Icons.keyboard_double_arrow_up,
                                      '跳跃',
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _touch(
                                          'up arrow',
                                          Icons.arrow_upward,
                                          '上',
                                        ),
                                        const SizedBox(width: 8),
                                        _touch(
                                          'down arrow',
                                          Icons.arrow_downward,
                                          '下',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            if (runtime.paused)
                              ColoredBox(
                                color: Colors.black54,
                                child: Center(
                                  child: FilledButton.icon(
                                    onPressed: _pause,
                                    icon: const Icon(Icons.play_arrow),
                                    label: const SiteText('继续游戏'),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _touch(String key, IconData icon, String title) => Semantics(
    label: title,
    button: true,
    child: Listener(
      onPointerDown: (_) {
        _focus.requestFocus();
        _runtime?.key(key, true);
      },
      onPointerUp: (_) => _runtime?.key(key, false),
      onPointerCancel: (_) => _runtime?.key(key, false),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .32),
          border: Border.all(color: Colors.white54),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    ),
  );
  void _settings() {
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, local) => AlertDialog(
          title: const SiteText('游戏设置'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const SiteText('静音'),
                  value: session.muted,
                  onChanged: (v) {
                    session.configure(mute: v);
                    local(() {});
                  },
                ),
                Row(
                  children: [
                    const SiteText('音量'),
                    Expanded(
                      child: Slider(
                        value: session.volume,
                        onChanged: (v) {
                          session.configure(gain: v);
                          local(() {});
                        },
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const SiteText('触屏按键'),
                  value: session.touchControls,
                  onChanged: (v) {
                    session.configure(controls: v);
                    local(() {});
                  },
                ),
                const SiteText(
                  'P 暂停 / 继续；Esc 退出全屏。切到后台会暂停，返回后点击继续。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const SiteText('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leaderboard() => SiteCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const SiteText('积分榜', style: TextStyle(fontSize: 22)),
            Text(
              '${siteTr(context, 'gameCurrentScore')} ${_formatScore(session.score)}'
              '  ·  ${siteTr(context, 'gameBestScore')} ${_formatScore(session.best)}'
              '${session.rank > 0 ? '  ·  #${session.rank}' : ''}',
            ),
            IconButton(
              tooltip: '刷新积分榜',
              onPressed: session.loading ? null : session.refreshLeaderboard,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (!session.authenticated)
          TextButton(onPressed: _login, child: const SiteText('登录后自动记录最高分')),
        if (session.saving) const LinearProgressIndicator(),
        if (session.saveError.isNotEmpty)
          Row(
            children: [
              Expanded(child: Text(session.saveError)),
              TextButton(
                onPressed: session.flushScore,
                child: const SiteText('重试同步'),
              ),
            ],
          ),
        if (session.loading && session.entries.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(),
            ),
          ),
        if (session.error.isNotEmpty) Text(session.error),
        if (!session.loading &&
            session.entries.isEmpty &&
            session.error.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: SiteText('还没有上榜记录', textAlign: TextAlign.center),
          ),
        if (session.entries.isNotEmpty)
          SizedBox(
            height: math.min(session.entries.length * 60.0, 420),
            child: ListView.builder(
              itemCount: session.entries.length,
              itemBuilder: (context, i) {
                final e = session.entries[i],
                    name = userDisplayName(e, fallback: '月');
                return ListTile(
                  selected:
                      session.authenticated &&
                      '${e['userId']}' == widget.controller.account?.id,
                  selectedTileColor: RoomStyle(context).primary
                      .withValues(alpha: .1),
                  leading: SizedBox(
                    width: 60,
                    child: Row(
                      children: [
                        Text('${e['rank'] ?? i + 1}'),
                        const SizedBox(width: 8),
                        SiteAvatar(
                          value: '${e['avatar'] ?? ''}',
                          name: name.trim().toUpperCase(),
                          site: widget.controller.settings.siteUrl,
                          size: 30,
                        ),
                      ],
                    ),
                  ),
                  title: Text(name, overflow: TextOverflow.ellipsis),
                  trailing: Text(
                    _formatScore((e['score'] as num?)?.toInt() ?? 0),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
  String _formatScore(int value) =>
      '$value'.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  @override
  void dispose() {
    _loadTicket++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    session.removeListener(_sessionChanged);
    session.dispose();
    _audio?.dispose();
    _runtime?.dispose();
    _assets?.dispose();
    _focus.dispose();
    unawaited(widget.controller.resumeBackgroundMusic());
    super.dispose();
  }
}
