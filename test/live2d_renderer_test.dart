import 'package:flutter_test/flutter_test.dart';

import 'support/live2d_render_probe.dart';

void main() {
  testWidgets(
    'animated opacity attenuates normal and masked additive highlights',
    (tester) async {
      final actual = (await tester.runAsync(probeLive2DOpacity))!;
      for (final entry in expectedLive2DOpacity.entries) {
        for (var channel = 0; channel < 4; channel++) {
          expect(
            actual[entry.key]![channel],
            closeTo(entry.value[channel], 2),
            reason: '${entry.key} channel $channel',
          );
        }
      }
    },
  );
}
