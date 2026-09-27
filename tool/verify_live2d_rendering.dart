// Run on a device: flutter run -d macos -t tool/verify_live2d_rendering.dart
// Widget tests use a different renderer and cannot alone verify Metal output.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import '../test/support/live2d_render_probe.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Checking native rendering…'))),
    ),
  );
  ui.Image? atlas;
  final frames = <ui.Image>[];
  Live2DModel? model;
  final lines = <String>[];
  try {
    final pixels = await probeLive2DOpacity();
    var passed = true;
    for (final entry in expectedLive2DOpacity.entries) {
      final actual = pixels[entry.key]!;
      final ok = List.generate(
        4,
        (i) => (actual[i] - entry.value[i]).abs() <= 2,
      ).every((v) => v);
      passed = passed && ok;
      lines.add('${ok ? 'PASS' : 'FAIL'} ${entry.key}: $actual');
    }
    final output = Directory(
      '${Directory.systemTemp.path}/tsukuyomi-render-check',
    );
    await output.create(recursive: true);
    await File('${output.path}/pixels.json').writeAsString(
      jsonEncode({
        'passed': passed,
        'pixels': pixels,
        'expected': expectedLive2DOpacity,
      }),
    );
    try {
      model = await loadLive2D();
      // The second natural blink begins at ~5.608 s. Preserve all preceding
      // physics updates, then inspect the full reopen and settling period.
      for (var frame = 0; frame < 195; frame++) {
        model.tick(frame / 30, 1 / 30);
        if (frame < 165) continue;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(const Color(0xff13192b), BlendMode.src);
        canvas.scale(3);
        canvas.translate(-290, -85);
        Live2DPainter(model).paint(canvas, const Size(720, 960));
        final picture = recorder.endRecording();
        frames.add(await picture.toImage(420, 330));
        picture.dispose();
      }
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var i = 0; i < frames.length; i++) {
        canvas.drawImage(
          frames[i],
          Offset((i % 6) * 420, (i ~/ 6) * 330),
          Paint(),
        );
      }
      final picture = recorder.endRecording();
      atlas = await picture.toImage(2520, 1650);
      picture.dispose();
      final png = await atlas.toByteData(format: ui.ImageByteFormat.png);
      await File('${output.path}/blink.png')
          .writeAsBytes(png!.buffer.asUint8List());
      lines.add('30 native blink frames: 5.500–6.467 s');
    } catch (error) {
      lines.add('Model capture unavailable: $error');
    }
    lines.add('Artifacts: ${output.path}');
  } catch (error) {
    lines.add('FAIL: $error');
  } finally {
    for (final image in frames) {
      image.dispose();
    }
    model?.dispose();
  }
  final report = lines.join('\n');
  // The UI makes a device check reviewable without reading a host log.
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xff13192b),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  report,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              if (atlas != null)
                Expanded(
                  child: RawImage(image: atlas, fit: BoxFit.contain),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
