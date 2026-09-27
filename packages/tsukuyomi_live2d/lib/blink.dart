import 'dart:math' as math;

/// Website Room timing: close, briefly hold, then reopen more gently.
/// A closed hold also survives a 30 Hz animation tick instead of falling
/// between two frames and driving a sharp reversal into eye physics.
double naturalBlinkOpen(double seconds, {double baseOpen = .92}) {
  if (!seconds.isFinite) return baseOpen.clamp(.62, 1);
  final time = math.max(0.0, seconds);
  final open = baseOpen.clamp(.62, 1.0);
  final approximate = ((time - 1.35) / 4.2).floor();
  for (final index in [approximate - 1, approximate, approximate + 1]) {
    if (index < 0) continue;
    final seed = math.sin((index + 1) * 12.9898 + 78.233) * 43758.5453;
    final jitter = ((seed - seed.floor()) - .5) * .9;
    final local = time - (1.35 + index * 4.2 + jitter);
    if (local < 0) continue;
    if (local < .13) {
      final t = local / .13;
      return .015 + (open - .015) * (1 - t * t);
    }
    if (local < .205) return .015;
    if (local < .415) {
      final t = (local - .205) / .21;
      return .015 + (open - .015) * (1 - (1 - t) * (1 - t));
    }
  }
  return open;
}
