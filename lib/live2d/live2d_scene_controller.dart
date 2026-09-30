import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

/// Owns the single clock/model/painter shared by the embedded and full scene.
class Live2DSceneController {
  Live2DSceneController({
    required TickerProvider vsync,
    required this.mobile,
    required this.onTick,
  }) {
    ticker = vsync.createTicker(_tick);
    SchedulerBinding.instance.addTimingsCallback(_timings);
  }
  final bool mobile;
  final void Function(double seconds, double delta) onTick;
  late final Ticker ticker;
  Live2DModel? model;
  Live2DPainter? painter;
  Duration? _last;
  double _seconds = 0;
  int _slow = 0, _good = 0;
  bool _active = false;
  int get fps => mobile || _slow >= 12 ? 30 : 60;

  void attach(Live2DModel value) {
    painter?.dispose();
    model?.dispose();
    model = value;
    painter = Live2DPainter(value);
  }

  set active(bool value) {
    if (_active == value) return;
    _active = value;
    _last = null;
    if (value && model != null) {
      ticker.start();
    } else {
      ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (_last == null) {
      _last = elapsed;
      return;
    }
    final micros = (elapsed - _last!).inMicroseconds;
    // A small tolerance avoids halving a nominal 60Hz display's update rate.
    if (micros < 1000000 / fps - 1000) return;
    _last = elapsed;
    final delta = (micros / 1000000).clamp(0.0, .05);
    _seconds += delta;
    onTick(_seconds, delta);
  }

  void _timings(List<FrameTiming> timings) {
    if (!_active || mobile) return;
    for (final frame in timings) {
      final work = math.max(
        frame.buildDuration.inMicroseconds,
        frame.rasterDuration.inMicroseconds,
      );
      if (work > 16667) {
        _slow = (_slow + 1).clamp(0, 12);
        _good = 0;
      } else if (work < 12000) {
        if (++_good >= 240) {
          _slow = 0;
          _good = 0;
        }
      } else {
        _good = 0;
      }
    }
  }

  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    ticker.dispose();
    painter?.dispose();
    model?.dispose();
    model = null;
  }
}
