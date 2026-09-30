import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/room_archive.dart';
import '../core/room_reference.dart';

class RoomAnimation extends ChangeNotifier {
  final List<Map<String, dynamic>> queue = [], history = [];
  Map<String, dynamic>? current;
  double elapsed = 0, x = 0, y = 0, rotation = 0, scale = 1;
  bool ready = false;
  String expression = 'neutral', status = 'idle';
  final Map<String, double> parameters = {};
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
    final duration = (intent['durationMs'] as num? ?? 5000).clamp(800, 12000);
    queue.add({...intent, 'durationMs': duration});
    status = ready ? 'queued' : 'pending';
    notifyListeners();
  }

  void clear() {
    queue.clear();
    current = null;
    elapsed = 0;
    parameters.clear();
    expression = 'neutral';
    x = y = rotation = 0;
    scale = 1;
    status = 'idle';
    notifyListeners();
  }

  void react(String text) {
    final emotion = RegExp(r'难过|哭|泪|伤心').hasMatch(text)
        ? 'tears'
        : RegExp(r'害羞|脸红|不好意思').hasMatch(text)
        ? 'bsmile'
        : RegExp(r'开心|哈哈|太好了|嘿嘿|～|♪').hasMatch(text)
        ? 'smile'
        : 'neutral';
    enqueue({
      'expression': emotion,
      'motion': emotion == 'tears'
          ? 'lean_in'
          : emotion == 'smile'
          ? 'nod'
          : 'sway',
      'durationMs': 3200,
    });
  }

  void advance(double delta) {
    if (!ready) return;
    if (current == null && queue.isNotEmpty) {
      current = queue.removeAt(0);
      elapsed = 0;
      expression = '${current!['expression'] ?? 'neutral'}';
      status = 'playing';
      history.insert(0, {
        ...current!,
        'startedAt': DateTime.now().toIso8601String(),
      });
      if (history.length > 20) history.removeLast();
      notifyListeners();
    }
    if (current == null) return;
    elapsed += delta * 1000;
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
    final e =
            envelope *
            (current!['intensity'] as num? ?? 1).toDouble().clamp(.5, 1),
        fast = math.sin(t * math.pi * 4),
        slow = math.sin(t * math.pi * 2),
        beat = math.sin(t * math.pi * 2).abs();
    parameters.clear();
    final preset = RoomReference.rows('expressions')
        .where((v) => v['id'] == expression)
        .firstOrNull;
    for (final p in jsonRows(preset?['cubism'])) {
      parameters['${p['id']}'] = (p['value'] as num).toDouble();
    }
    // Semantic expressions that have no separate .exp3 file are applied through the rig.
    if (['closed_smile', 'closed_eyes'].contains(expression)) {
      parameters.addAll({'ParamEyeLOpen': 0, 'ParamEyeROpen': 0});
    }
    if (expression.contains('wink')) parameters['ParamEyeROpen'] = 0;
    final motion = '${current!['motion'] ?? current!['bodyPose'] ?? ''}';
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
    for (final action in [
      ...jsonRows(preset?['actions']),
      ...jsonRows(current!['actions']),
    ]) {
      final definition = RoomReference.rows('actions')
          .where((v) => v['id'] == action['type'])
          .firstOrNull;
      for (final p in jsonRows(definition?['parameters'])) {
        final delay = (action['delay'] as num? ?? 0) * 1000;
        final duration =
            (action['duration'] as num? ??
                (definition?['defaultDurationMs'] as num? ?? 1600) / 1000) *
            1000;
        final progress = ((elapsed - delay) / duration).clamp(0.0, 1.0);
        if (elapsed < delay || progress >= 1) continue;
        final amount = math.sin(progress * math.pi);
        parameters['${p['id']}'] =
            (p['value'] as num? ?? p['min'] as num? ?? 0).toDouble() * amount;
      }
    }
    for (final p in jsonRows(current!['parameters'])) {
      final id = '${p['id']}';
      final value = p['value'];
      if (value is num && value.isFinite) {
        parameters[id] = value.toDouble().clamp(-100, 100);
      }
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
    if (value['sequence'] is List) {
      for (final item in jsonRows(value['sequence']).take(30)) {
        enqueue(item);
      }
    } else {
      enqueue(jsonMap(value));
    }
  }
}
