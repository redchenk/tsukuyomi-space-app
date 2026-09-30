import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/room_archive.dart';
import '../core/room_reference.dart';
import 'live2d_semantics.dart';

class RoomAnimation extends ChangeNotifier {
  final List<Map<String, dynamic>> queue = [], history = [];
  Map<String, dynamic>? current;
  double elapsed = 0, x = 0, y = 0, rotation = 0, scale = 1;
  bool ready = false;
  String expression = 'neutral', status = 'idle';
  final Map<String, double> parameters = {};
  Map<String, double> _blendFrom = {};
  bool _started = false;
  Map<String, dynamic> get debug => {
    'status': status,
    'ready': ready,
    'current': current,
    'remaining': queue.length,
    'expression': expression,
    'parameters': parameters,
    'history': history,
  };
  void enqueue(Map<String, dynamic> intent) {
    final step = Live2DSemantics.step(intent);
    if (step == null) return;
    if (current != null) {
      final next = jsonMap(step['interruptPolicy']),
          previous = jsonMap(current!['interruptPolicy']);
      final mode = next['mode'];
      final interrupt =
          mode == 'replace' ||
          (mode != 'queue' &&
              mode != 'ignore' &&
              !(previous['mode'] == 'protect' &&
                  elapsed < (previous['minHoldMs'] as num)) &&
              (elapsed >= (current!['durationMs'] as num) * .58 ||
                  (step['priority'] as num) >= (current!['priority'] as num)));
      if (interrupt) {
        _blendFrom = Map.of(parameters);
        current = null;
        queue.insert(0, step);
      } else if (mode != 'ignore') {
        queue.add(step);
      }
    } else {
      queue.add(step);
    }
    if (queue.length > 32) queue.removeLast();
    status = ready ? 'queued' : 'pending';
    notifyListeners();
  }

  void clear() {
    queue.clear();
    current = null;
    elapsed = 0;
    _started = false;
    _blendFrom = {};
    parameters.clear();
    expression = 'neutral';
    x = y = rotation = 0;
    scale = 1;
    status = 'idle';
    notifyListeners();
  }

  void react(String text) {
    enqueue(Live2DSemantics.infer(text));
  }

  void advance(double delta) {
    if (!ready) return;
    if (current == null && queue.isNotEmpty) {
      current = queue.removeAt(0);
      elapsed = -(current!['delayMs'] as num).toDouble();
      _started = false;
      status = 'playing';
    }
    if (current == null) return;
    elapsed += delta * 1000;
    if (elapsed < 0) return;
    if (!_started) {
      _started = true;
      expression = '${current!['expression'] ?? 'neutral'}';
      history.insert(0, {
        ...current!,
        'startedAt': DateTime.now().toIso8601String(),
      });
      if (history.length > 20) history.removeLast();
      notifyListeners();
    }
    final duration = (current!['durationMs'] as num).toDouble();
    final t = (elapsed / duration).clamp(0.0, 1.0);
    double ease(double value) {
      final v = value.clamp(0.0, 1.0);
      return v < .5 ? 4 * v * v * v : 1 - math.pow(-2 * v + 2, 3) / 2;
    }

    final envelope = t < .18
        ? ease(t / .18)
        : t > .84
        ? ease((1 - t) / .16)
        : 1.0;
    parameters.clear();
    for (final layer in jsonRows(current!['expressionMix'])) {
      final definition = RoomReference.rows('expressions')
          .where((e) => e['id'] == layer['expression'])
          .firstOrNull;
      for (final p in jsonRows(definition?['cubism'])) {
        final id = '${p['id']}';
        parameters[id] =
            (parameters[id] ?? 0) +
            (p['value'] as num).toDouble() *
                (layer['weight'] as num).toDouble();
      }
    }
    // Semantic expressions that have no separate .exp3 file are applied through the rig.
    if (['closed_smile', 'closed_eyes'].contains(expression)) {
      parameters.addAll({'ParamEyeLOpen': 0, 'ParamEyeROpen': 0});
    }
    if (expression.contains('wink')) parameters['ParamEyeROpen'] = 0;
    final active = jsonRows(current!['behaviorActions'])
        .where(
          (a) =>
              elapsed >= (a['delayMs'] as num) &&
              elapsed <= (a['delayMs'] as num) + (a['durationMs'] as num),
        )
        .toList();
    final body =
        active
            .where(
              (a) => Live2DSemantics.definition(a['type'])?['bodyPose'] != null,
            )
            .toList()
          ..sort(
            (a, b) =>
                ((Live2DSemantics.definition(b['type'])?['vtsPriority']
                                as num? ??
                            0) *
                        (b['intensity'] as num))
                    .compareTo(
                      (Live2DSemantics.definition(a['type'])?['vtsPriority']
                                  as num? ??
                              0) *
                          (a['intensity'] as num),
                    ),
          );
    final dominant = body.firstOrNull;
    final phase = dominant == null
        ? t
        : ((elapsed - (dominant['delayMs'] as num)) /
                  (dominant['durationMs'] as num))
              .clamp(0.0, 1.0);
    final bodyEnvelope = phase < .28
        ? ease(phase / .28)
        : phase > .76
        ? ease((1 - phase) / .24)
        : 1.0;
    final e =
        (dominant == null ? envelope : bodyEnvelope) *
        (dominant?['intensity'] as num? ?? current!['intensity'] as num)
            .toDouble();
    final fast = math.sin(phase * math.pi * 4),
        slow = math.sin(phase * math.pi * 2),
        beat = math.sin(phase * math.pi * 2).abs();
    final motion =
        '${dominant == null ? current!['bodyPose'] ?? '' : Live2DSemantics.definition(dominant['type'])?['bodyPose']}';
    x = y = rotation = 0;
    scale = 1;
    switch (motion) {
      case 'nod':
        y = 2.6 * beat * e;
        scale = 1 + .002 * beat * e;
        rotation = -.22 * fast * e;
        parameters['ParamAngle_HeadY'] = -12 * beat * e;
      case 'shake_head':
        x = 20 * fast * e;
        y = .8 * beat * e;
        rotation = 2.2 * fast * e;
        parameters['ParamAngle_HeadX'] = 18 * fast * e;
      case 'lean_in':
        y = -8 * e;
        rotation = .28 * slow * e;
        scale = 1 + .015 * e;
      case 'lean_left':
        x = -36 * e;
        y = 2 * e;
        scale = 1 + .005 * e;
        rotation = -2.7 * e;
      case 'lean_right':
        x = 36 * e;
        y = 2 * e;
        scale = 1 + .005 * e;
        rotation = 2.7 * e;
      case 'sway':
        x = 34 * slow * e;
        y = 1.4 * beat * e;
        scale = 1 + .003 * slow.abs() * e;
        rotation = 2.1 * slow * e;
      case 'bounce':
        x = 5 * slow * e;
        y = -11 * beat * e;
        rotation = .58 * slow * e;
        scale = 1 + .009 * beat * e;
      case 'emphasis':
        x = 11 * slow * e;
        y = -7 * math.sin(t * math.pi).abs() * e;
        rotation = -1.2 * slow * e;
        scale = 1 + .012 * math.sin(t * math.pi).abs() * e;
    }
    for (final action in active) {
      for (final p in Live2DSemantics.targets(action)) {
        _applyTarget(p, ease);
      }
    }
    for (final p in jsonRows(current!['parameters'])) {
      _applyTarget(p, ease);
    }
    if (_blendFrom.isNotEmpty) {
      final blendMs = (jsonMap(current!['interruptPolicy'])['blendInMs'] as num)
          .toDouble();
      final weight = blendMs <= 0 ? 1.0 : ease(elapsed / blendMs);
      for (final id in {..._blendFrom.keys, ...parameters.keys}) {
        parameters[id] =
            (_blendFrom[id] ?? 0) * (1 - weight) +
            (parameters[id] ?? 0) * weight;
      }
      if (weight >= 1) _blendFrom = {};
    }
    if (t >= 1) {
      current = null;
      parameters.clear();
      expression = 'neutral';
      x = y = rotation = 0;
      scale = 1;
      status = queue.isEmpty ? 'idle' : 'queued';
      notifyListeners();
    }
  }

  void custom(dynamic value) {
    if (value is! Map) throw const ApiFailure('Live2D 指令必须是 JSON 对象');
    final sequence = Live2DSemantics.sequence(jsonMap(value));
    if (sequence.isEmpty) throw const ApiFailure('没有可执行的 Live2D 表情、语义动作或参数');
    for (var i = 0; i < sequence.length; i++) {
      final step = sequence[i];
      enqueue({
        ...step,
        if (i > 0)
          'interruptPolicy': {
            ...jsonMap(step['interruptPolicy']),
            'mode': 'queue',
          },
      });
    }
  }

  void _applyTarget(Map<String, dynamic> p, double Function(double) ease) {
    final delay = (p['delayMs'] as num).toDouble(),
        duration = (p['durationMs'] as num).toDouble();
    if (elapsed < delay || elapsed > delay + duration) return;
    final progress = ((elapsed - delay) / duration).clamp(0.0, 1.0);
    final envelope = progress < .28
        ? ease(progress / .28)
        : progress > .76
        ? ease((1 - progress) / .24)
        : 1.0;
    final id = '${p['id']}', value = (p['value'] as num).toDouble();
    final baseline =
        parameters[id] ??
        (id == 'ParamEyeLOpen' || id == 'ParamEyeROpen' ? 1 : 0);
    final weight = (p['weight'] as num? ?? 1).toDouble().clamp(0, 1) * envelope;
    parameters[id] = (baseline + (value - baseline) * weight).clamp(-100, 100);
  }
}
