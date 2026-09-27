import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

void main() {
  testWidgets('native blink sequence renders through closed eyes', (
    tester,
  ) async {
    final model = (await tester.runAsync(() => loadLive2D()))!;
    try {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xff13192b), BlendMode.src);
        final times = List.generate(24, (i) => 5.5 + i / 30);
        var current = 0.0;
        for (var i = 0; i < times.length; i++) {
          while (current + .00001 < times[i]) {
            final delta = (times[i] - current).clamp(0.0, 1 / 30);
            current += delta;
            model.tick(current, delta);
          }
          canvas.save();
          canvas.translate((i % 6) * 420, (i ~/ 6) * 330);
          canvas.clipRect(const Rect.fromLTWH(0, 0, 420, 330));
          canvas.scale(3);
          canvas.translate(-290, -85);
          Live2DPainter(model).paint(canvas, const Size(720, 960));
          canvas.restore();
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(2520, 1320);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          'artifacts/blink-${const String.fromEnvironment('BLINK_LABEL', defaultValue: 'current')}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
    } finally {
      model.dispose();
    }
  }, skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'));
}
