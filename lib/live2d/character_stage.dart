import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/rendering.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../core/voice_service.dart';
import '../core/models.dart';
import '../core/room_reference.dart';
import '../core/room_archive.dart';
import '../core/room_files.dart';
import 'room_animation.dart';
import 'live2d_scene_controller.dart';
import '../features/room/room_style.dart';

class CharacterStage extends StatefulWidget {
  const CharacterStage({
    super.key,
    required this.voice,
    this.loadNative = true,
    this.mobile = false,
    this.keyboardOpen = false,
    this.onSettings,
    this.onReady,
    this.onMusic,
    this.musicTitle = 'Remember',
    this.musicPlaying = false,
    this.musicLoading = false,
    this.onMusicToggle,
    this.modelLoader,
    this.animation,
    this.settings = const RoomSettings(),
    this.world = const {},
    this.onWorld,
    this.onVoiceSettings,
  });
  final VoiceService voice;
  final RoomAnimation? animation;
  final RoomSettings settings;
  final Map<String, dynamic> world;
  final VoidCallback? onWorld, onVoiceSettings;
  final bool loadNative, mobile, keyboardOpen;
  final VoidCallback? onSettings, onMusic;
  final String musicTitle;
  final bool musicPlaying, musicLoading;
  final VoidCallback? onMusicToggle;
  final ValueChanged<bool>? onReady;
  final Future<Live2DModel> Function()? modelLoader;
  @override
  State<CharacterStage> createState() => _CharacterStageState();
}

class _CharacterStageState extends State<CharacterStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Live2DModel? get _model => _sceneController.model;
  final _captureKey = GlobalKey(), _fullCaptureKey = GlobalKey();
  final _sceneRevision = ValueNotifier<int>(0);
  String? _failure;
  late final Live2DSceneController _sceneController;
  bool _routeVisible = true, _fullscreen = false;
  double _x = 0, _y = 0;
  bool _paused = false;
  bool _visible = true;
  String _expression = 'neutral';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visible =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _sceneController = Live2DSceneController(
      vsync: this,
      mobile:
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS,
      onTick: (seconds, delta) {
        widget.animation?.advance(delta.clamp(0, .05));
        _model?.parameterOverrides = widget.animation?.parameters ?? {};
        _model?.tick(
          seconds,
          delta.clamp(0, .05),
          mouth: widget.voice.mouth,
          lookX: _x,
          lookY: _y,
          expression: widget.animation?.current != null
              ? widget.animation!.expression
              : _expression,
        );
      },
    );
    if (widget.loadNative) unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    _updateScene(() => _failure = null);
    try {
      final model = await (widget.modelLoader ?? loadLive2D)();
      if (!mounted) {
        model.dispose();
        return;
      }
      _updateScene(() => _sceneController.attach(model));
      if (widget.animation != null) widget.animation!.ready = true;
      widget.onReady?.call(true);
      _syncTicker();
    } catch (e) {
      if (mounted) _updateScene(() => _failure = e.toString());
    }
  }

  void _toggleMotion() {
    _updateScene(() => _paused = !_paused);
    _syncTicker();
  }

  void _updateScene(VoidCallback update) {
    if (!mounted) return;
    setState(update);
    _sceneRevision.value++;
  }

  void _syncTicker() {
    if (!mounted) return;
    _sceneController.active =
        _visible &&
        (_routeVisible || _fullscreen) &&
        !_paused &&
        _model != null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant CharacterStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The fullscreen route is outside this widget's subtree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sceneRevision.value++;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _syncTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sceneController.dispose();
    _sceneRevision.dispose();
    if (widget.animation != null) widget.animation!.ready = false;
    super.dispose();
  }

  void _diagnostics() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('角色状态'),
      content: Text(
        _model == null
            ? (_failure ?? '正在载入原生 Live2D 模型…')
            : 'Cubism Native · ${_model!.meshes.length} 个网格\n最近模型更新 ${_model!.updateMilliseconds.toStringAsFixed(1)} ms\n自适应帧率，此数值不包含 GPU 绘制耗时。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (_failure != null)
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _load();
            },
            child: const Text('重新载入'),
          ),
      ],
    ),
  );

  Widget _character() => LayoutBuilder(
    builder: (context, box) => MouseRegion(
      onHover: (e) {
        _x = (e.localPosition.dx / box.maxWidth * 2 - 1).clamp(-1, 1);
        _y = (1 - e.localPosition.dy / box.maxHeight * 2).clamp(-1, 1);
      },
      onExit: (_) {
        _x = 0;
        _y = 0;
      },
      child: Semantics(
        label: '月见八千代',
        image: true,
        child: _model == null
            ? Image.asset(
                'assets/images/yachiyo-hub-stand.png',
                fit: BoxFit.contain,
                excludeFromSemantics: true,
              )
            : AnimatedBuilder(
                animation: _model!,
                child: RepaintBoundary(
                  child: CustomPaint(painter: _sceneController.painter),
                ),
                builder: (context, child) {
                  final a = widget.animation;
                  return Transform.translate(
                    offset: Offset(
                      widget.settings.number('modelX', 0) + (a?.x ?? 0),
                      widget.settings.number('modelY', 0) + (a?.y ?? 0),
                    ),
                    child: Transform.rotate(
                      angle: (a?.rotation ?? 0) * 3.141592653589793 / 180,
                      child: Transform.scale(
                        scale:
                            widget.settings.number('modelScale', 100) /
                            100 *
                            (a?.scale ?? 1),
                        child: child,
                      ),
                    ),
                  );
                },
              ),
      ),
    ),
  );

  Widget _scene({bool expanded = false}) => LayoutBuilder(
    builder: (context, box) {
      final mobile = widget.mobile && !expanded;
      final p = RoomStyle(context);
      return ClipRRect(
        borderRadius: BorderRadius.circular(mobile || expanded ? 0 : 21),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/room-night-apartment.webp',
              fit: BoxFit.cover,
              excludeFromSemantics: true,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: mobile
                      ? const [Color(0x30221f36), Color(0xa51b172b)]
                      : const [Color(0x291c2639), Color(0x3d1f2637)],
                ),
              ),
            ),
            Positioned(
              top: mobile ? box.maxHeight * .085 : 16,
              left: mobile ? -box.maxWidth * .25 : -box.maxWidth * .005,
              width: box.maxWidth * (mobile ? 1.5 : 1.08),
              height: box.maxHeight * (mobile ? .90 : .86),
              child: _fullscreen && !expanded
                  ? const SizedBox.shrink()
                  : _character(),
            ),
            if (!mobile) ...[
              Positioned(
                top: 25,
                left: 25,
                right: 135,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• LIVE2D ROOM${widget.world['city'] == null ? '' : ' · ${widget.world['city']}'}',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 2.5,
                        color: Color(0xffd8d1e9),
                      ),
                    ),
                    const SizedBox(height: 11),
                    Text(
                      '八千代的房间',
                      style: TextStyle(
                        fontFamily: RoomStyle.serif,
                        fontSize: (box.maxWidth * .043).clamp(23, 34),
                        color: const Color(0xfff5f1fa),
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      '和八千代一起，把时间慢下来。',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xffe1dcea),
                        height: 1.7,
                      ),
                    ),
                  ],
                ),
              ),
              if (box.maxWidth > 580)
                Positioned(
                  left: 26,
                  top: box.maxHeight * .26,
                  child: Container(
                    width: 190,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 17,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: p.glass,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: Radius.circular(18),
                        bottomLeft: Radius.circular(18),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Text(
                      '你来啦。刚好，\n给自己留一点放空的时间。',
                      style: TextStyle(fontSize: 12, height: 2, color: p.ink),
                    ),
                  ),
                ),
              Positioned(
                left: 28,
                bottom: 112,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'YACHIYO',
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 2.6,
                        color: Color(0xffd8d1e9),
                      ),
                    ),
                    const SizedBox(height: 9),
                    const Text(
                      '八千代',
                      style: TextStyle(
                        fontFamily: RoomStyle.serif,
                        fontSize: 34,
                        letterSpacing: 4,
                        color: Color(0xfff5f1fa),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 5,
                          color: _model == null
                              ? Colors.grey
                              : const Color(0xff87c8b1),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _model == null ? '角色预览' : '正在听你说',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xffe1dcea),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 25,
                bottom: 114,
                child: Text(
                  '此\n刻\n，\n在\n月\n读\n相\n遇\n。',
                  style: const TextStyle(
                    fontSize: 9,
                    height: 1.4,
                    color: Color(0xffe1dcea),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 20,
                child: _toolbar(expanded),
              ),
            ],
            if (!mobile || !widget.keyboardOpen)
              Positioned(
                top: mobile ? 150 : 23,
                right: mobile ? 16 : 24,
                child: Column(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: mobile ? p.glass : const Color(0x44514b62),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(
                          color: mobile ? p.line : const Color(0x40e5e1ef),
                        ),
                      ),
                      child: TextButton.icon(
                        onPressed: _sceneInfo,
                        style: TextButton.styleFrom(
                          foregroundColor: mobile
                              ? p.ink
                              : const Color(0xfff5f1fa),
                          minimumSize: Size(0, mobile ? 44 : 34),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        icon: const Icon(CupertinoIcons.moon, size: 16),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('月夜小屋', style: TextStyle(fontSize: 12)),
                            const SizedBox(width: 8),
                            const Icon(CupertinoIcons.chevron_down, size: 10),
                          ],
                        ),
                      ),
                    ),
                    if (mobile) ...[
                      const SizedBox(height: 7),
                      Text(
                        _model == null
                            ? (_failure == null
                                  ? '正在载入 Live2D…'
                                  : 'Live2D 载入失败')
                            : '在这里，陪着你',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xfff5f1fa),
                          shadows: [
                            Shadow(color: Color(0xff17162c), blurRadius: 8),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (!mobile && _model == null)
              Positioned(
                right: 26,
                top: 68,
                child: TextButton(
                  onPressed: _failure == null ? null : _load,
                  child: Text(
                    _failure == null ? 'Live2D 载入中…' : '载入失败 · 重试',
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  void _sceneInfo() {
    if (widget.onWorld != null) {
      widget.onWorld!();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('月夜小屋'),
        content: const Text('此刻，在月读相遇。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _diagnostics();
            },
            child: const Text('角色状态'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onSettings?.call();
            },
            child: const Text('房间与角色设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveScreenshot(bool expanded) async {
    try {
      final boundary =
          (expanded ? _fullCaptureKey : _captureKey).currentContext!
                  .findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || bytes == null) return;
      await exportRoomFile(
        context,
        bytes.buffer.asUint8List(),
        'tsukuyomi-room-${DateTime.now().millisecondsSinceEpoch}.png',
        'image/png',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('截图保存失败，请重试')));
      }
    }
  }

  Widget _toolbar(bool expanded) {
    final p = RoomStyle(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: p.glass,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(15),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: widget.onMusic,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.waveform, size: 21, color: p.muted),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '房间音乐',
                              style: TextStyle(fontSize: 10, color: p.muted),
                            ),
                            Text(
                              widget.musicTitle,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 8, color: p.muted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: widget.musicPlaying ? '暂停音乐' : '播放音乐',
              onPressed: widget.musicLoading ? null : widget.onMusicToggle,
              icon: widget.musicLoading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      widget.musicPlaying
                          ? CupertinoIcons.pause_fill
                          : CupertinoIcons.play_fill,
                      size: 16,
                    ),
            ),
            PopupMenuButton<String>(
              tooltip: '表情',
              initialValue: _expression,
              enabled: _model != null,
              onSelected: (v) {
                if (widget.animation != null) {
                  widget.animation!.enqueue({
                    'expression': v,
                    'durationMs': 5000,
                  });
                } else {
                  _updateScene(() => _expression = v);
                }
              },
              itemBuilder: (_) => [
                for (final e in jsonRows(
                  RoomReference.map('live2d')['expressions'],
                ))
                  PopupMenuItem(
                    value: '${e['id']}',
                    child: Text('${e['label']}'),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.heart, size: 18, color: p.muted),
                    if (box.maxWidth > 520) ...[
                      const SizedBox(width: 5),
                      const Text('表情', style: TextStyle(fontSize: 10)),
                    ],
                  ],
                ),
              ),
            ),
            PopupMenuButton<String>(
              tooltip: '动作',
              enabled: _model != null,
              onSelected: (v) {
                if (v == 'pause') {
                  _toggleMotion();
                } else {
                  widget.animation?.enqueue({'motion': v, 'durationMs': 2800});
                }
              },
              itemBuilder: (_) => [
                for (final m in jsonRows(
                  RoomReference.map('live2d')['motions'],
                ))
                  PopupMenuItem(
                    value: '${m['id']}',
                    child: Text('${m['label']}'),
                  ),
                PopupMenuItem(
                  value: 'pause',
                  child: Text(_paused ? '继续动作' : '暂停动作'),
                ),
              ],
              icon: const Icon(CupertinoIcons.move, size: 17),
            ),
            if (box.maxWidth > 520) const SizedBox(width: 10),
            IconButton(
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(32, 32),
                padding: const EdgeInsets.all(6),
              ),
              tooltip: '保存角色截图',
              onPressed: () => _saveScreenshot(expanded),
              icon: const Icon(CupertinoIcons.camera, size: 17),
            ),
            IconButton(
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(32, 32),
                padding: const EdgeInsets.all(6),
              ),
              tooltip: expanded ? '退出全屏舞台' : '全屏角色舞台',
              onPressed: expanded
                  ? () => Navigator.pop(context)
                  : _openFullscreen,
              icon: Icon(
                expanded
                    ? CupertinoIcons.fullscreen_exit
                    : CupertinoIcons.fullscreen,
                size: 17,
              ),
            ),
            FilledButton.icon(
              onPressed: widget.onVoiceSettings ?? widget.onSettings,
              style: FilledButton.styleFrom(
                backgroundColor: p.primary,
                foregroundColor: p.onPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size(0, 34),
              ),
              icon: const Icon(CupertinoIcons.speaker_2, size: 16),
              label: Text(
                box.maxWidth > 450 ? '语音设置' : '语音',
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openFullscreen() async {
    _updateScene(() => _fullscreen = true);
    _syncTicker();
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => AnimatedBuilder(
          animation: _sceneRevision,
          builder: (_, _) => Dialog.fullscreen(
            child: RepaintBoundary(
              key: _fullCaptureKey,
              child: _scene(expanded: true),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        _updateScene(() => _fullscreen = false);
        _syncTicker();
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _captureKey, child: _scene());
}
