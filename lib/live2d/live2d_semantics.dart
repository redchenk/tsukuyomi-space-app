import 'dart:convert';
import 'dart:math' as math;

import '../core/room_archive.dart';
import '../core/room_reference.dart';
import 'live2d_semantic_data.dart';

class Live2DSemantics {
  static final data = jsonMap(jsonDecode(live2dSemanticJson));
  static final List<Map<String, dynamic>> actions = jsonRows(data['actions']);
  static final _actionIndex = <String, Map<String, dynamic>>{
    for (final action in actions.reversed)
      for (final alias in [action['id'], ...action['aliases'] as List])
        token(alias): action,
  };
  static final _expressionIndex = <String, String>{
    for (final expression in RoomReference.rows('expressions').reversed)
      for (final alias in [
        expression['id'],
        expression['emotion'],
        ...expression['aliases'] as List,
      ])
        if (token(alias).isNotEmpty) token(alias): '${expression['id']}',
  };
  static final _parameterIndex = <String, Map<String, dynamic>>{
    for (final control in jsonRows(
      RoomReference.map('live2d')['parameterControls'],
    ))
      token(control['id']): control,
  };
  static String get controlPrompt => '${data['controlPrompt']}';
  static String get streamingPrompt => '${data['streamingPrompt']}';
  static String token(dynamic value) =>
      '${value ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_');
  static double bound(dynamic value, double min, double max, double fallback) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse('${value ?? ''}');
    return number == null || !number.isFinite
        ? fallback
        : number.clamp(min, max);
  }

  static Map<String, dynamic>? definition(dynamic value) {
    return _actionIndex[token(value)];
  }

  static String expression(dynamic value) {
    return _expressionIndex[token(value)] ?? '';
  }

  static List<Map<String, dynamic>> normalizeActions(
    dynamic value, {
    double intensity = .72,
  }) {
    if (value is! List) return [];
    final output = <Map<String, dynamic>>[];
    var offset = 0.0;
    for (final raw in value.take(8)) {
      final item = raw is String ? {'type': raw} : jsonMap(raw);
      final def = definition(
        item['type'] ??
            item['action'] ??
            item['name'] ??
            item['motion'] ??
            item['id'],
      );
      if (def == null) continue;
      final seconds = double.tryParse('${item['duration'] ?? item['seconds']}');
      final duration = bound(
        item['durationMs'] ?? (seconds == null ? null : seconds * 1000),
        260,
        5200,
        (def['defaultDurationMs'] as num).toDouble(),
      );
      final delaySeconds = double.tryParse(
        '${item['delay'] ?? item['offset']}',
      );
      final hasDelay = [
        'delayMs',
        'offsetMs',
        'delay',
        'offset',
      ].any(item.containsKey);
      final delay = bound(
        item['delayMs'] ??
            item['offsetMs'] ??
            (delaySeconds == null ? null : delaySeconds * 1000),
        0,
        12000,
        offset,
      );
      final side = token(item['side'] ?? item['direction']);
      output.add({
        'type': def['id'],
        'side': switch (side) {
          'l' => 'left',
          'r' => 'right',
          'u' => 'up',
          'd' => 'down',
          'left' || 'right' || 'up' || 'down' => side,
          _ => def['defaultSide'] ?? '',
        },
        'target': '${item['target'] ?? item['to'] ?? ''}'.trim(),
        'intensity': bound(
          item['intensity'] ?? item['strength'],
          .05,
          1,
          intensity,
        ),
        'durationMs': duration,
        'delayMs': delay,
        'style': token(item['style']),
      });
      if (!hasDelay) offset += (duration * .72).round();
    }
    return output;
  }

  static List<Map<String, dynamic>> targets(Map action) {
    final def = definition(action['type']);
    final side = '${action['side'] ?? ''}';
    final variants = jsonMap(def?['targets']);
    final raw = jsonRows(variants[side] ?? variants['']);
    return [
      for (final p in raw)
        {
          ...p,
          'value':
              (p['constant'] as num).toDouble() +
              (p['coefficient'] as num).toDouble() *
                  bound(action['intensity'], .05, 1, .72),
          'durationMs': action['durationMs'],
          'delayMs': action['delayMs'],
        },
    ];
  }

  static List<Map<String, dynamic>> parameters(dynamic value) {
    final source = value is List
        ? jsonRows(value)
        : value is Map
        ? [
            for (final entry in value.entries)
              {
                'id': entry.key,
                ...(entry.value is Map
                    ? jsonMap(entry.value)
                    : {'value': entry.value}),
              },
          ]
        : <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final p in source) {
      final key = token(
        p['id'] ?? p['parameterId'] ?? p['param'] ?? p['key'] ?? p['name'],
      );
      final control = _parameterIndex[key];
      final v = double.tryParse(
        '${p['value'] ?? p['target'] ?? p['amount'] ?? p['to']}',
      );
      if (control == null || v == null || !v.isFinite) continue;
      result.add({
        'id': control['id'],
        'value': v.clamp(
          (control['min'] as num).toDouble(),
          (control['max'] as num).toDouble(),
        ),
        'weight': bound(p['weight'], 0, 1, .85),
        'durationMs': bound(
          p['durationMs'] ?? p['duration'] ?? p['timeMs'] ?? p['time'],
          250,
          12000,
          900,
        ),
        'delayMs': bound(
          p['delayMs'] ?? p['delay'] ?? p['offsetMs'],
          0,
          12000,
          0,
        ),
      });
    }
    return result.take(18).toList();
  }

  static Map<String, dynamic> policy(dynamic value, double priority) {
    final raw = value is String ? {'mode': value} : jsonMap(value);
    final mode = token(raw['mode'] ?? raw['type']);
    return {
      'mode': ['blend', 'replace', 'queue', 'protect', 'ignore'].contains(mode)
          ? mode
          : 'blend',
      'priority': bound(raw['priority'], 0, 10, priority),
      'minHoldMs': bound(raw['minHoldMs'] ?? raw['min_hold_ms'], 0, 5000, 260),
      'blendInMs': bound(raw['blendInMs'] ?? raw['blend_in_ms'], 0, 1200, 300),
      'blendOutMs': bound(
        raw['blendOutMs'] ?? raw['blend_out_ms'],
        0,
        1200,
        520,
      ),
    };
  }

  static Map<String, dynamic>? step(Map input) {
    final nested = jsonMap(input['live2d'] ?? input['act'] ?? input['pose']);
    final item = {...input, ...nested};
    var face = expression(
      item['expression'] ??
          item['expressionId'] ??
          item['face'] ??
          item['emotion'] ??
          item['mood'],
    );
    final intensity = bound(item['intensity'], 0, 1, .65);
    final mixes = <String, double>{};
    for (final layer in jsonRows(item['expressionMix'])) {
      final id = expression(layer['expression'] ?? layer['key'] ?? layer['id']);
      final weight = bound(layer['weight'], 0, 1, id == face ? 1 : .5);
      if (id.isNotEmpty && weight > .02) {
        mixes[id] = ((mixes[id] ?? 0) + weight).clamp(0, 1);
      }
    }
    final layers = mixes.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (layers.isNotEmpty) face = layers.first.key;
    final motion = definition(
      item['bodyPose'] ??
          item['pose'] ??
          item['posture'] ??
          item['motion'] ??
          item['action'],
    );
    var semantic = normalizeActions(
      item['behaviorActions'] ?? item['actions'],
      intensity: intensity,
    );
    if (semantic.isEmpty && motion != null) {
      semantic = normalizeActions([
        {
          'type': motion['id'],
          'durationMs': item['durationMs'] ?? item['duration'],
        },
      ], intensity: intensity);
    }
    final preset = RoomReference.rows('expressions')
        .where((e) => e['id'] == face)
        .firstOrNull;
    final seen = semantic.map((a) => a['type']).toSet();
    final extras = jsonRows(preset?['actions'])
        .where((a) => !seen.contains(a['type']))
        .take(math.max(0, 5 - semantic.length));
    semantic = [
      ...semantic,
      ...normalizeActions(extras.toList(), intensity: intensity),
    ];
    final params = parameters(
      item['parameters'] ?? item['parameterTargets'] ?? item['params'],
    );
    if (face.isEmpty && semantic.isEmpty && params.isEmpty) return null;
    final actionPriority = semantic
        .map(
          (a) =>
              (definition(a['type'])?['vtsPriority'] as num? ?? 0).toDouble(),
        )
        .fold(0.0, math.max);
    final priority = bound(
      item['priority'],
      0,
      10,
      (1 +
              actionPriority * .72 +
              intensity * 1.5 +
              (face.isNotEmpty && face != 'neutral' ? 0.4 : 0))
          .clamp(0, 10),
    );
    final duration = bound(
      item['durationMs'] ?? item['duration'],
      800,
      12000,
      semantic
          .map(
            (a) =>
                (a['delayMs'] as num).toDouble() +
                (a['durationMs'] as num).toDouble(),
          )
          .fold(1200.0, math.max)
          .clamp(800, 12000),
    );
    return {
      'expression': face.isEmpty ? 'neutral' : face,
      'emotion': item['emotion'] ?? item['mood'],
      'expressionMix': layers.isEmpty
          ? [
              {'expression': face, 'weight': 1.0},
            ]
          : [
              for (final l in layers.take(3))
                {'expression': l.key, 'weight': l.value},
            ],
      'motion': motion?['bodyPose'] ?? '',
      'bodyPose': motion?['bodyPose'] ?? '',
      'behaviorActions': semantic,
      'parameters': params,
      'intensity': intensity,
      'durationMs': duration,
      'delayMs': bound(item['delayMs'] ?? item['delay'], 0, 12000, 0),
      'priority': priority,
      'interruptPolicy': policy(
        item['interruptPolicy'] ?? item['interrupt'],
        priority,
      ),
      'speechStyle': item['speechStyle'] ?? item['speech_style'],
    };
  }

  static List<Map<String, dynamic>> sequence(Map input) {
    final nested = jsonMap(input['live2d'] ?? input['act']);
    final raw = input['sequence'] ?? nested['sequence'];
    if (raw is List && raw.isNotEmpty) {
      return [for (final item in jsonRows(raw).take(12)) ?step(item)];
    }
    final value = step(input);
    return value == null ? [] : [value];
  }

  static Map<String, dynamic> infer(String text) {
    final emotional = jsonRows(data['emotionMatchers'])
        .where(
          (e) => RegExp('${e['pattern']}', caseSensitive: false).hasMatch(text),
        )
        .firstOrNull;
    final act = actions
        .where(
          (a) =>
              '${a['fallbackPattern']}'.isNotEmpty &&
              RegExp(
                '${a['fallbackPattern']}',
                caseSensitive: a['caseInsensitive'] != true,
              ).hasMatch(text),
        )
        .firstOrNull;
    return step({
      'expression': emotional?['expression'] ?? 'neutral',
      'emotion': emotional?['emotion'] ?? 'neutral',
      'actions':
          act?['fallbackActions'] ??
          [
            {'type': 'look_at_chat', 'duration': 1.0},
            {'type': 'breathe', 'duration': 1.8, 'delay': .1},
          ],
    })!;
  }
}
