import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/animation_parameters.dart';
import 'package:tsukuyomi_studio_motion/tsukuyomi_studio_motion.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_semantics.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

void main() {
  final source = File('assets/live2d/studio-motion.js').readAsStringSync();
  StudioRuntime runtime() {
    final result = createStudioRuntime(source);
    addTearDown(result.dispose);
    return result;
  }

  test(
    'native Studio matches original JavaScript through 900 frames and handoffs',
    () {
      final engine = runtime();
      final fixture = jsonDecode(
        File('test/fixtures/studio_motion_reference.json').readAsStringSync(),
      ) as Map;
      for (final row in fixture['frames'] as List) {
        final result = engine.invoke(Map<String, dynamic>.from(row['input']));
        if (!row.containsKey('expected')) continue;
        final expected = row['expected'] as Map;
        final parameters = expected['parameters'] as List?;
        if (parameters == null) {
          expect(result, expected, reason: '${row['input']}');
          continue;
        }
        expect(result['parameters'].length, parameters.length);
        for (var i = 0; i < parameters.length; i++) {
          final actual = result['parameters'][i] as Map;
          expect(actual['id'], parameters[i]['id']);
          expect(
            actual['value'],
            closeTo(parameters[i]['value'] as num, .00001),
          );
          expect(
            actual['weight'],
            closeTo(parameters[i]['weight'] as num, .00001),
          );
        }
        for (final key in ['expression', 'active', 'planActive', 'mode']) {
          expect(result[key], expected[key], reason: '${row['input']} $key');
        }
      }
    },
  );

  test(
    'idle is alive, speech follows real amplitude and releases smoothly',
    () {
      final engine = runtime()..invoke({'kind': 'reset', 'seed': 919});
      final values = <double>[];
      final modes = <String>[];
      for (var i = 0; i < 600; i++) {
        final frame = engine.invoke({
          'kind': 'frame',
          'now': 1000 + i * 1000 / 60,
          'mouth': i >= 120 && i < 240 ? .6 : 0,
        });
        modes.add(frame['mode'] as String);
        final parameters = frame['parameters'] as List;
        values.add(
          (parameters.firstWhere((p) => p['id'] == 'ParamAngleX')['value']
                  as num)
              .toDouble(),
        );
        for (final p in parameters) {
          expect((p['value'] as num).isFinite, isTrue);
          expect(p['weight'], inInclusiveRange(0, 1));
        }
      }
      expect(
        values.take(120).reduce(math.max) - values.take(120).reduce(math.min),
        greaterThan(.1),
      );
      expect(modes[200], 'speaking');
      expect(modes.last, anyOf('idle', 'listening'));
      // There must not be a hard reset when audio falls silent.
      expect((values[240] - values[239]).abs(), lessThan(3));
    },
  );

  test('all semantic actions reach Studio and leave the room layout fixed', () {
    for (final action in Live2DSemantics.actions) {
      final animation = RoomAnimation()
        ..attachStudio(runtime())
        ..ready = true;
      animation.custom({
        'behaviorActions': [
          {'type': action['id'], 'durationMs': 1200},
        ],
        'durationMs': 1400,
      });
      for (var i = 0; i < 45; i++) {
        animation.advance(1 / 60);
        expect(
          animation.parameters.length,
          greaterThan(50),
          reason: '${action['id']}',
        );
        expect(
          [animation.x, animation.y, animation.rotation, animation.scale],
          [0, 0, 0, 1],
        );
      }
      expect(animation.history, hasLength(1), reason: '${action['id']}');
      expect(animation.parameterWeights.keys, animation.parameters.keys);
      animation.dispose();
    }
  });

  test('protection queues, replacement interrupts and queued acts finish', () {
    final animation = RoomAnimation()
      ..attachStudio(runtime())
      ..ready = true;
    addTearDown(animation.dispose);
    Map<String, dynamic> act(String action, String mode) => {
      'label': action,
      'durationMs': 900,
      'behaviorActions': [
        {'type': action, 'durationMs': 800},
      ],
      'interruptPolicy': {'mode': mode, 'minHoldMs': 800},
    };
    animation.custom(act('nod', 'protect'));
    animation.advance(.04);
    animation.custom(act('sway', 'blend'));
    expect(
      (animation.current?['behaviorActions'] as List?)?.first['type'],
      'nod',
    );
    expect(animation.queue, hasLength(1));
    animation.custom(act('bounce', 'replace'));
    expect(
      (animation.current?['behaviorActions'] as List?)?.first['type'],
      'bounce',
    );
    for (var i = 0; i < 300; i++) {
      animation.advance(1 / 60);
    }
    expect(animation.queue, isEmpty);
    expect(animation.current, isNull);
    expect(
      animation.history.map(
        (e) => (e['behaviorActions'] as List).first['type'],
      ),
      ['sway', 'bounce', 'nod'],
    );
    expect(
      animation.parameters,
      isNotEmpty,
      reason: 'Natural idle remains after acts',
    );
    final frozen = Map.of(animation.parameters);
    animation.ready = false;
    animation.advance(60);
    expect(animation.parameters, frozen);
  });

  test(
    'weighted rig transport preserves audio authority without legacy idle',
    () {
      final writes = <(String, double, int)>[];
      applyLive2DParameters(
        (id, value, blend) => writes.add((id, value, blend)),
        seconds: 1,
        mouth: 0,
        lookX: 1,
        lookY: 1,
        expression: [
          {'Id': 'ParamEyeLOpen', 'Value': 0, 'Blend': 'Multiply'},
        ],
        overrides: {'ParamAngle_HeadX': 12, 'ParamMouthOpenY': .8},
        weights: {'ParamAngle_HeadX': .3, 'ParamMouthOpenY': .9},
        studioMotion: true,
      );
      expect(writes, [
        ('ParamAngle_HeadX', 12.0, weightedParameterBlend(.3)),
        ('ParamMouthOpenY', .8, weightedParameterBlend(.9)),
        ('ParamMouthOpenY', 0.0, 0),
      ]);
      for (final value in [0.0, .001, .3, .5, .999, 1.0]) {
        final blend = weightedParameterBlend(value);
        expect(blend >> 16, 1);
        expect((blend & 65535) / 65535, closeTo(value, 1 / 131070));
      }
    },
  );

  test('isolated runtime rejects malformed commands and disposes safely', () {
    final engine = runtime();
    expect(() => engine.invoke({'kind': 'unknown'}), throwsStateError);
    expect(engine.invoke({'kind': 'reset'}), {'ready': true});
    engine.dispose();
    engine.dispose();
    expect(() => engine.invoke({'kind': 'frame'}), throwsStateError);
    expect(
      () => createStudioRuntime('throw new Error("bad bundle")'),
      throwsStateError,
    );
    final isolated = createStudioRuntime(
      'globalThis.__studioInvoke = () => ({network: typeof fetch, fs: typeof require, host: typeof process});',
    );
    expect(isolated.invoke({}), {
      'network': 'undefined',
      'fs': 'undefined',
      'host': 'undefined',
    });
    isolated.dispose();
  });
}
