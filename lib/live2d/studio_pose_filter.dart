import 'dart:math' as math;

/// A short, time-based settling layer for Studio's parameter arbitration.
///
/// Studio may switch the dominant action/weight in one display frame. Smooth
/// the weighted contribution and weight together, so Cubism's model-default
/// contribution stays correct without guessing the rig's default values.
/// The upstream trajectory remains unchanged; this only settles its handoffs.
class StudioPoseFilter {
  final _states = <String, _WeightedPose>{};

  void clear() => _states.clear();

  void apply(
    Map<String, double> values,
    Map<String, double> weights,
    double delta,
  ) {
    if (delta <= 0 || !delta.isFinite) return;
    final ids = {..._states.keys, ...values.keys};
    for (final id in ids) {
      // Audio owns the mouth. Rig routing switches must stay discrete.
      if (id == 'ParamMouthOpenY' || id.startsWith('ParamSwitchCtrl_')) {
        continue;
      }
      final present = values.containsKey(id);
      final weight = present ? (weights[id] ?? 1).clamp(0.0, 1.0) : 0.0;
      final contribution = present ? values[id]! * weight : 0.0;
      final state = _states.putIfAbsent(
        id,
        () => _WeightedPose(contribution, weight),
      );
      final response = _response(id);
      state.contribution.step(contribution, delta, response);
      state.weight.step(weight, delta, response);
      final blendedWeight = state.weight.value.clamp(0.0, 1.0);
      if (!present && blendedWeight < .0001) {
        _states.remove(id);
        continue;
      }
      weights[id] = blendedWeight;
      values[id] = blendedWeight > .000001
          ? state.contribution.value / blendedWeight
          : values[id] ?? 0;
    }
  }

  double _response(String id) {
    // Natural blinks/quick glances keep their timing; shoulders trail the head.
    if (id == 'ParamEyeLOpen' || id == 'ParamEyeROpen') return .018;
    if (id.startsWith('ParamEyeBall')) return .035;
    if (const ['ParamAngleX', 'ParamAngleY', 'ParamAngleZ'].contains(id)) {
      return .065;
    }
    if (id.contains('Body') ||
        id.contains('Chest') ||
        id.contains('Hip') ||
        id.startsWith('Position') ||
        id.startsWith('ParamPosition')) {
      return .09;
    }
    if (id.contains('Physics') || id.contains('Shoulder')) return .08;
    return .055;
  }
}

class _WeightedPose {
  _WeightedPose(double value, double amount)
    : contribution = _Spring(value),
      weight = _Spring(amount);
  final _Spring contribution, weight;
}

class _Spring {
  _Spring(this.value);
  double value, velocity = 0;

  void step(double target, double delta, double response) {
    // Exact critically damped solution for a constant target during this step.
    // No frame-count coefficient or Euler instability at 30/60/120 Hz.
    final omega = 2 / response;
    final offset = value - target;
    final impulse = velocity + omega * offset;
    final decay = math.exp(-omega * delta);
    value = target + (offset + impulse * delta) * decay;
    velocity = (velocity - omega * impulse * delta) * decay;
  }
}
