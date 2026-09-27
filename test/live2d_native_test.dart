import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

void main() {
  testWidgets('real Cubism model deforms and renders with native physics', (
    tester,
  ) async {
    final model = await tester.runAsync(() => loadLive2D());
    expect(model, isNotNull);
    final scene = model!;
    try {
      expect(scene.meshes.length, greaterThan(100));
      final before = scene.meshes.expand((m) => m.positions).toList();
      scene.tick(1, 1 / 60, mouth: .8, lookX: .6, expression: 'smile');
      expect(
        scene.meshes.expand((m) => m.positions).toList(),
        isNot(equals(before)),
      );
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xff13192b), BlendMode.src);
        Live2DPainter(scene).paint(canvas, const Size(720, 960));
        final picture = recorder.endRecording();
        final image = await picture.toImage(720, 960);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('artifacts/native-live2d.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
    } finally {
      scene.dispose();
    }
  }, skip: !const bool.fromEnvironment('RUN_CUBISM_TESTS'));
}
