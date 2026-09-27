import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../core/voice_service.dart';

class CharacterStage extends StatefulWidget {
  const CharacterStage({
    super.key,
    required this.voice,
    this.loadNative = true,
  });
  final VoiceService voice;
  final bool loadNative;
  @override
  State<CharacterStage> createState() => _CharacterStageState();
}

class _CharacterStageState extends State<CharacterStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Live2DModel? _model;
  String? _failure;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _seconds = 0, _x = 0, _y = 0;
  bool _paused = false, _diagnostics = false;
  String _expression = 'neutral';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((elapsed) {
      if (_last == Duration.zero) {
        _last = elapsed;
        return;
      }
      final delta = (elapsed - _last).inMicroseconds / 1000000;
      if (delta < 1 / 30) return; // Explicit prototype update budget, not a measured GPU frame rate.
      _last = elapsed;
      _seconds += delta;
      _model?.tick(
        _seconds,
        delta,
        mouth: widget.voice.mouth,
        lookX: _x,
        lookY: _y,
        expression: _expression,
      );
    });
    if (widget.loadNative) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final model = await loadLive2D();
      if (!mounted) {
        model.dispose();
        return;
      }
      setState(() => _model = model);
      _ticker.start();
    } catch (e) {
      if (mounted) setState(() => _failure = e.toString());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_paused && _model != null) {
      _last = Duration.zero;
      if (!_ticker.isActive) _ticker.start();
    } else if (state != AppLifecycleState.resumed) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _model?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 340;
      return ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/room-bg.webp',
              fit: BoxFit.cover,
              excludeFromSemantics: true,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x880b1022),
                    Color(0x770e1631),
                    Color(0xff111729),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 24,
              left: 24,
              right: 24,
              child: Row(
                children: [
                  const Icon(
                    Icons.nightlight_round,
                    size: 16,
                    color: Color(0xffded2ff),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    constraints.maxWidth < 360 ? '居所' : 'PRIVATE ROOM',
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 2.5,
                      color: Color(0xffe0d5f8),
                    ),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: _model != null
                        ? 'Cubism Native · 原生网格绘制'
                        : '角色插画预览',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x660b1020),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _model != null ? 'LIVE2D NATIVE' : 'PREVIEW',
                        style: const TextStyle(fontSize: 9, letterSpacing: 1.2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              top: compact ? 12 : 78,
              bottom: compact ? 0 : 100,
              child: LayoutBuilder(
                builder: (context, box) => MouseRegion(
                  onHover: (e) {
                    _x = (e.localPosition.dx / box.maxWidth * 2 - 1).clamp(
                      -1,
                      1,
                    );
                    _y = (1 - e.localPosition.dy / box.maxHeight * 2).clamp(
                      -1,
                      1,
                    );
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
                        : RepaintBoundary(
                            child: CustomPaint(painter: Live2DPainter(_model!)),
                          ),
                  ),
                ),
              ),
            ),
            if (!compact)
              Positioned(
                left: 28,
                right: 28,
                bottom: 26,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '月见八千代',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '把今天的心事，慢慢说给我听。',
                      style: TextStyle(color: Color(0xffc1c5d5), fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        for (final entry in const {
                          'neutral': '日常',
                          'smile': '微笑',
                          'tears': '泪光',
                        }.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                entry.value,
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: _expression == entry.key,
                              onSelected: _model == null
                                  ? null
                                  : (_) =>
                                        setState(() => _expression = entry.key),
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        const Spacer(),
                        IconButton(
                          tooltip: _paused ? '继续动作' : '暂停动作',
                          icon: Icon(
                            _paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            size: 20,
                          ),
                          onPressed: _model == null
                              ? null
                              : () => setState(() {
                                  _paused = !_paused;
                                  if (_paused) {
                                    _ticker.stop();
                                  } else {
                                    _last = Duration.zero;
                                    _ticker.start();
                                  }
                                }),
                        ),
                        IconButton(
                          tooltip: '渲染状态',
                          icon: const Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                          ),
                          onPressed: () =>
                              setState(() => _diagnostics = !_diagnostics),
                        ),
                      ],
                    ),
                    if (_diagnostics)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _model == null
                              ? (_failure ?? '正在加载角色；插画可用于界面预览。')
                              : 'Cubism Native · ${_model!.meshes.length} 个网格\n最近模型更新 ${_model!.updateMilliseconds.toStringAsFixed(1)} ms · 更新上限 30 Hz\n此数值不包含 GPU 绘制耗时。',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xffb8bcd0),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}
