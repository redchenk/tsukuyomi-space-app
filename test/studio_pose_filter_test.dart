import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/live2d/studio_pose_filter.dart';

void main() {
  test('pose settling is time based at 30, 60 and 120 Hz', () {
    final endpoints = <double>[];
    for (final hz in [30, 60, 120]) {
      final filter = StudioPoseFilter();
      filter.apply({'ParamAngleX': 0}, {'ParamAngleX': 1}, 1 / hz);
      var previous = 0.0;
      for (var i = 0; i < hz ~/ 5; i++) {
        final pose = {'ParamAngleX': 20.0};
        filter.apply(pose, {'ParamAngleX': 1}, 1 / hz);
        expect(pose['ParamAngleX'], inInclusiveRange(previous, 20));
        previous = pose['ParamAngleX']!;
      }
      endpoints.add(previous);
    }
    expect(endpoints.first, greaterThan(19.5));
    for (final value in endpoints) {
      expect(value, closeTo(endpoints.first, 1e-10));
    }
  });

  test('weighted transitions preserve nonzero model defaults', () {
    final weighted = StudioPoseFilter(), reference = StudioPoseFilter();
    const rest = 7.0;
    final targets = [(4.0, .8), (20.0, .25), (-10.0, .9), (0.0, 0.0)];
    for (final (target, amount) in targets) {
      for (var i = 0; i < 12; i++) {
        final values = {'ParamAngleX': target};
        final weights = {'ParamAngleX': amount};
        weighted.apply(values, weights, 1 / 60);
        final pose = {'ParamAngleX': rest * (1 - amount) + target * amount};
        reference.apply(pose, {'ParamAngleX': 1}, 1 / 60);
        final actual =
            rest * (1 - weights['ParamAngleX']!) +
            values['ParamAngleX']! * weights['ParamAngleX']!;
        expect(actual, closeTo(pose['ParamAngleX']!, 1e-9));
        expect(weights['ParamAngleX'], inInclusiveRange(0, 1));
      }
    }
  });

  test(
    'head settles before shoulders without delaying audio or rig switches',
    () {
      final filter = StudioPoseFilter();
      filter.apply({'ParamAngleX': 0, 'ParamBodyInput_BodyX': 0}, {}, 1 / 60);
      final pose = {
        'ParamAngleX': 10.0,
        'ParamBodyInput_BodyX': 10.0,
        'ParamMouthOpenY': .8,
        'ParamSwitchCtrl_BodyX': 1.0,
      };
      filter.apply(pose, {}, 1 / 60);
      expect(pose['ParamAngleX'], inExclusiveRange(0, 2));
      expect(pose['ParamBodyInput_BodyX'], lessThan(pose['ParamAngleX']!));
      expect(pose['ParamMouthOpenY'], .8);
      expect(pose['ParamSwitchCtrl_BodyX'], 1);
      final silence = {'ParamMouthOpenY': 0.0, 'ParamSwitchCtrl_BodyX': 0.0};
      filter.apply(silence, {}, 1 / 60);
      expect(silence['ParamMouthOpenY'], 0);
      expect(silence['ParamSwitchCtrl_BodyX'], 0);
    },
  );

  test('natural blink still closes and reopens in a short blink window', () {
    final filter = StudioPoseFilter();
    filter.apply({'ParamEyeLOpen': 1}, {}, 1 / 60);
    for (final target in [0.0, 1.0]) {
      final result = <String, double>{};
      for (var i = 0; i < 3; i++) {
        result['ParamEyeLOpen'] = target;
        filter.apply(result, {}, 1 / 60);
      }
      expect(result['ParamEyeLOpen'], closeTo(target, .03));
    }
  });

  test('removed controls fade out and a new model starts without old pose', () {
    final filter = StudioPoseFilter();
    filter.apply({'ParamAngleX': 20}, {'ParamAngleX': .8}, 1 / 60);
    var previous = .8;
    for (var i = 0; i < 60; i++) {
      final values = <String, double>{}, weights = <String, double>{};
      filter.apply(values, weights, 1 / 60);
      final amount = weights['ParamAngleX'] ?? 0;
      expect(amount, inInclusiveRange(0, previous));
      previous = amount;
      if (amount > 0) expect(values['ParamAngleX'], closeTo(20, 1e-9));
    }
    expect(previous, 0);
    filter.clear();
    final replacement = {'ParamAngleX': -12.0};
    filter.apply(replacement, {}, 1 / 60);
    expect(replacement['ParamAngleX'], -12);
  });
}
