import 'dart:math' as math;

import 'blink.dart';

// Preserve the existing parameter-batch ABI across JNI, Metal, GL and D3D.
// 0/1/2 retain set/add/multiply; bit 16 selects a weighted set, low 16 bits
// encode Cubism's blend weight. Error is at most 1/131070.
int weightedParameterBlend(double weight) =>
    0x10000 | (weight.clamp(0, 1) * 65535).round();

/// Identical parameter order for Canvas and native GPU (expression blend order
/// matters). Voice amplitude is supplied from the audio playback clock.
void applyLive2DParameters(
  void Function(String id, double value, int blend) apply, {
  required double seconds,
  required double mouth,
  required double lookX,
  required double lookY,
  required List<Map<String, dynamic>> expression,
  required Map<String, double> overrides,
  Map<String, double> weights = const {},
  bool studioMotion = false,
}) {
  if (!studioMotion) {
    apply('ParamAngleX', lookX * 18 + math.sin(seconds * .43) * 3, 0);
    apply('ParamAngleY', lookY * 12 + math.sin(seconds * .37) * 2, 0);
    apply('ParamAngleZ', math.sin(seconds * .61) * 2, 0);
    apply('ParamBodyAngleX', math.sin(seconds * .4) * 2, 0);
    apply('ParamBreath', .5 + math.sin(seconds * 1.6) * .45, 0);
    final blink = naturalBlinkOpen(seconds);
    apply('ParamEyeLOpen', blink, 0);
    apply('ParamEyeROpen', blink, 0);
    apply('ParamEyeBallX', lookX * .7, 0);
    apply('ParamEyeBallY', lookY * .7, 0);
    for (final p in expression) {
      apply(
        p['Id'] as String,
        (p['Value'] as num).toDouble(),
        switch (p['Blend']) {
          'Add' => 1,
          'Multiply' => 2,
          _ => 0,
        },
      );
    }
  }
  for (final p in overrides.entries) {
    apply(
      p.key,
      p.value,
      weights.containsKey(p.key) ? weightedParameterBlend(weights[p.key]!) : 0,
    );
  }
  apply('ParamMouthOpenY', mouth.clamp(0, 1), 0);
}
