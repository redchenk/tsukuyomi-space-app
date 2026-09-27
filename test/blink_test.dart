import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/blink.dart';

void main() {
  test('blink has a visible closed hold at 30 Hz and returns smoothly', () {
    final frames = List.generate(90, (i) => naturalBlinkOpen(i / 30));
    final closed = frames.indexWhere((value) => value <= .016);
    expect(closed, greaterThan(0));
    expect(frames[closed + 1], closeTo(.015, .001));
    final recovering = frames.skip(closed + 3).take(8).toList();
    for (var i = 1; i < recovering.length; i++) {
      expect(recovering[i], greaterThanOrEqualTo(recovering[i - 1]));
    }
    expect(recovering.last, closeTo(.92, .001));
    expect(frames.every((v) => v >= .015 && v <= .92), isTrue);
    expect(naturalBlinkOpen(0), .92);
    expect(naturalBlinkOpen(double.nan), .92);
  });
}
