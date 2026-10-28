import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_studio_motion/tsukuyomi_studio_motion.dart';

import '../core/voice_service.dart';
import '../core/desktop_window.dart';
import '../core/season_theme.dart';
import '../core/site_localization.dart';
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
    this.interacting,
    this.onSettings,
    this.onReady,
    this.onMusic,
    this.musicTitle = 'Remember',
    this.musicPlaying = false,
    this.musicLoading = false,
    this.onMusicToggle,
    this.modelLoader,
    this.motionLoader,
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

  /// The Room activity bus adjusts Canvas cadence during active gestures and
  /// brief input/keyboard transitions without rebuilding or freezing the stage.
  final ValueListenable<bool>? interacting;
  final VoidCallback? onSettings, onMusic;
  final String musicTitle;
  final bool musicPlaying, musicLoading;
  final VoidCallback? onMusicToggle;
  final ValueChanged<bool>? onReady;
  final Future<Live2DModel> Function()? modelLoader;
  final Future<StudioRuntime> Function()? motionLoader;
  @override
  State<CharacterStage> createState() => _CharacterStageState();
}

class _CharacterStageState extends State<CharacterStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Live2DModel? get _model => _sceneController.model;
  final _captureKey = GlobalKey(), _fullCaptureKey = GlobalKey();
  final _sceneRevision = ValueNotifier<int>(0);
  final _poseRevision = ValueNotifier<int>(0);
  (double, double, double, double) _pose = (0, 0, 0, 1);
  String? _failure;
  late final Live2DSceneController _sceneController;
  bool _routeVisible = true, _fullscreen = false;
  Timer? _lightingTimer;
  bool _day = roomDaytime(DateTime.now());

  void _syncLighting() {
    _lightingTimer?.cancel();
    if (!mounted || !_visible || !(_routeVisible || _fullscreen)) return;
    final date = DateTime.now();
    final day = roomDaytime(date);
    if (_day != day) _updateScene(() => _day = day);
    _lightingTimer = Timer(nextRoomLightingDelay(date), _syncLighting);
  }

  bool _paused = false;
  bool _visible = true;
  DesktopWindowController? _window;
  String _expression = 'neutral';
  final _idleAnimation = RoomAnimation();
  RoomAnimation get _animation => widget.animation ?? _idleAnimation;
  RoomAnimation? _boundAnimation;
  StudioRuntime? _studioRuntime;
  int _loadRevision = 0;
  String? _gpuFailure;
  int _textureLimit(RoomSettings settings) =>
      Live2DSceneController.textureLimitFor(
        settings.option('live2dRenderQuality', 'auto'),
      );
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
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform.name == 'ohos',
      onTick: (seconds, delta) {
        _animation.advance(delta.clamp(0, .05), mouth: widget.voice.mouth);
        final animation = _animation;
        final pose = (
          animation.x,
          animation.y,
          animation.rotation,
          animation.scale,
        );
        if (pose != _pose) {
          _pose = pose;
          _poseRevision.value++;
        }
        _model
          ?..parameterOverrides = animation.parameters
          ..parameterWeights = animation.parameterWeights
          ..studioMotion = animation.usesStudio;
        _model?.tick(
          seconds,
          delta.clamp(0, .05),
          mouth: widget.voice.mouth,
          expression: animation.usesStudio || animation.current != null
              ? animation.expression
              : _expression,
        );
      },
    );
    widget.interacting?.addListener(_syncInteraction);
    _syncInteraction();
    if (widget.loadNative) unawaited(_load());
  }

  Future<void> _load({bool canvasFallback = false}) async {
    if (!mounted) return;
    final revision = ++_loadRevision;
    _updateScene(() => _failure = null);
    StudioRuntime? pendingRuntime;
    Live2DModel? pendingModel;
    try {
      final model = pendingModel =
          await (widget.modelLoader?.call() ??
              loadLive2D(
                maxTextureSize: _textureLimit(widget.settings),
                renderer: canvasFallback
                    ? 'canvas'
                    : widget.settings.option('live2dRenderer', 'auto'),
              ));
      if (!mounted || revision != _loadRevision) {
        model.dispose();
        return;
      }
      pendingRuntime = widget.motionLoader == null
          ? createStudioRuntime(
              await rootBundle.loadString('assets/live2d/studio-motion.js'),
            )
          : await widget.motionLoader!();
      if (!mounted || revision != _loadRevision) {
        model.dispose();
        pendingRuntime.dispose();
        return;
      }
      if (canvasFallback) model.rendererFallbackReason = _gpuFailure;
      _boundAnimation?.detachStudio(_studioRuntime);
      _studioRuntime = pendingRuntime;
      _boundAnimation = _animation;
      _animation.attachStudio(pendingRuntime);
      pendingRuntime = null;
      _updateScene(() => _sceneController.attach(model));
      pendingModel = null;
      if (model is GpuLive2DModel) {
        var recovering = false;
        model.addListener(() {
          if (!recovering &&
              mounted &&
              identical(_model, model) &&
              model.failure != null) {
            recovering = true;
            _gpuFailure = model.failure;
            unawaited(_load(canvasFallback: true));
          }
        });
      }
      _animation.ready = true;
      widget.onReady?.call(true);
      _syncTicker();
    } catch (e) {
      pendingRuntime?.dispose();
      pendingModel?.dispose();
      if (mounted && revision == _loadRevision) {
        _updateScene(() => _failure = e.toString());
      }
    }
  }

  void _toggleMotion() {
    _updateScene(() => _paused = !_paused);
    _syncTicker();
    _syncLighting();
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
        _window?.minimized != true &&
        (_routeVisible || _fullscreen) &&
        !_paused &&
        _model != null;
  }

  void _syncInteraction() {
    if (!mounted) return;
    _sceneController.interacting = widget.interacting?.value ?? false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = DesktopWindowScope.maybeOf(context);
    if (window != _window) {
      _window?.removeListener(_syncTicker);
      _window = window;
      _window?.addListener(_syncTicker);
    }
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _syncTicker();
    _syncLighting();
  }

  @override
  void didUpdateWidget(covariant CharacterStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.interacting != widget.interacting) {
      oldWidget.interacting?.removeListener(_syncInteraction);
      widget.interacting?.addListener(_syncInteraction);
      _syncInteraction();
    }
    if (widget.loadNative && oldWidget.animation != widget.animation) {
      unawaited(_load());
    }
    if (widget.loadNative &&
        widget.modelLoader == null &&
        (_textureLimit(oldWidget.settings) != _textureLimit(widget.settings) ||
            oldWidget.settings.option('live2dRenderer', 'auto') !=
                widget.settings.option('live2dRenderer', 'auto'))) {
      unawaited(_load());
    }
    // The fullscreen route is outside this widget's subtree.
    if (_fullscreen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _fullscreen) _sceneRevision.value++;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    _syncTicker();
    _syncLighting();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _window?.removeListener(_syncTicker);
    widget.interacting?.removeListener(_syncInteraction);
    _lightingTimer?.cancel();
    _sceneController.dispose();
    _sceneRevision.dispose();
    _poseRevision.dispose();
    _boundAnimation?.detachStudio(_studioRuntime);
    _animation.ready = false;
    _idleAnimation.dispose();
    super.dispose();
  }

  String _rendererDiagnostics() {
    final model = _model!;
    final gpu = model is GpuLive2DModel ? model : null;
    return '${gpu == null ? "Flutter Canvas" : "Cubism GPU · ${gpu.backend}"} · ${gpu?.meshCount ?? model.meshes.length} 个网格\n'
        '最近模型更新 ${model.updateMilliseconds.toStringAsFixed(1)} ms\n'
        '${gpu == null ? "" : "模型加载 ${((gpu.loadMetrics['load_ms'] ?? 0) / 1000).toStringAsFixed(2)} s\n"}'
        '${gpu == null ? "" : "输出 ${gpu.actualWidth} × ${gpu.actualHeight} · DPR ${gpu.effectivePixelRatio.toStringAsFixed(2)}\n原生提交 ${gpu.submitMilliseconds.toStringAsFixed(1)} ms · 帧往返 ${gpu.frameMilliseconds.toStringAsFixed(1)} ms\n"}'
        '更新上限 ${_sceneController.fps} fps · 交互 ${_sceneController.interactionTransitions} 次\n'
        '计时为 CPU/提交耗时，非 GPU 执行时间。'
        '${model.rendererFallbackReason == null ? "" : "\nGPU 回退：${model.rendererFallbackReason}"}';
  }

  void _diagnostics() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('角色状态'),
      content: Text(
        _model == null
            ? (_failure ?? '正在载入原生 Live2D 模型…')
            : _rendererDiagnostics(),
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

  Widget _character() => Builder(
    builder: (context) {
      _sceneController.configure(
        quality:
            widget.settings.options['live2dRenderQuality']?.toString() ??
            'auto',
        frameLimit: widget.settings.number('live2dFrameRate', 0).toInt(),
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
        refreshRate: View.of(context).display.refreshRate,
      );
      return Semantics(
        label: '月见八千代',
        image: _model != null,
        child: _model == null
            ? const SizedBox.expand(key: Key('room-character-pending'))
            : AnimatedBuilder(
                // The painter listens directly to the model. Idle breathing
                // and blinking do not need to rebuild the transform widgets.
                animation: _poseRevision,
                child: RepaintBoundary(
                  child: _model is GpuLive2DModel
                      ? Live2DGpuView(
                          model: _model! as GpuLive2DModel,
                          quality: widget.settings.option(
                            'live2dRenderQuality',
                            'auto',
                          ),
                        )
                      : CustomPaint(painter: _sceneController.painter),
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
      );
    },
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
            RepaintBoundary(
              key: const Key('room-backdrop'),
              child: Image.asset(
                SeasonalArt(p.palette.season).room(_day),
                gaplessPlayback: true,
                cacheHeight:
                    (box.maxHeight * MediaQuery.devicePixelRatioOf(context))
                        .ceil()
                        .clamp(1, 1200),
                fit: BoxFit.cover,
                excludeFromSemantics: true,
              ),
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
                  : ClipRect(
                      key: const Key('room-character-viewport'),
                      child: RepaintBoundary(child: _character()),
                    ),
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
                          _model == null
                              ? siteTr(
                                  context,
                                  _failure == null
                                      ? 'nativeLive2dLoading'
                                      : 'nativeLive2dLoadFailed',
                                )
                              : siteTranslate(context, '正在听你说'),
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
                        icon: Icon(
                          _day ? CupertinoIcons.sun_max : CupertinoIcons.moon,
                          size: 16,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${siteTranslate(context, const {SiteSeason.spring: '樱花', SiteSeason.summer: '夏日', SiteSeason.autumn: '红叶', SiteSeason.winter: '冬雪'}[p.palette.season]!)} · ${siteTranslate(context, _day ? '白昼' : '月夜')}',
                              style: const TextStyle(fontSize: 12),
                            ),
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
                            ? siteTr(
                                context,
                                _failure == null
                                    ? 'nativeLive2dLoading'
                                    : 'nativeLive2dLoadFailed',
                              )
                            : siteTranslate(context, '在这里，陪着你'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xfff5f1fa),
                          shadows: [
                            Shadow(color: Color(0xff17162c), blurRadius: 8),
                          ],
                        ),
                      ),
                      if (_model == null && _failure != null)
                        TextButton(
                          key: const Key('live2d-retry'),
                          onPressed: _load,
                          child: Text(siteTr(context, 'nativeLive2dRetry')),
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
                  key: const Key('live2d-retry'),
                  onPressed: _failure == null ? null : _load,
                  child: Text(
                    siteTr(
                      context,
                      _failure == null
                          ? 'nativeLive2dLoading'
                          : 'nativeLive2dRetry',
                    ),
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
                _animation.enqueue({'expression': v, 'durationMs': 5000});
                _expression = v;
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
                  _animation.enqueue({'motion': v, 'durationMs': 2800});
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
