// Real Cubism + Flutter native rendering, with deterministic simulated speech.
// flutter run -d macos -t tool/verify_studio_motion.dart --dart-define=STUDIO_CAPTURE_DIR=/absolute/output
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_studio_motion/tsukuyomi_studio_motion.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('正在验证 Studio 原生动作…'))),
    ),
  );
  final output = Directory(
    const String.fromEnvironment(
      'STUDIO_CAPTURE_DIR',
      defaultValue: '/tmp/tsukuyomi-studio-motion',
    ),
  );
  await output.create(recursive: true);
  final animation = RoomAnimation();
  Live2DModel? model;
  Live2DPainter? painter;
  try {
    animation.attachStudio(
      createStudioRuntime(
        await rootBundle.loadString('assets/live2d/studio-motion.js'),
      ),
    );
    animation.ready = true;
    model = await loadLive2D(maxTextureSize: 3072, renderer: 'canvas');
    painter = Live2DPainter(model)..pixelRatio = 1;
    final motionMicros = <int>[];
    for (var i = 0; i < 600; i++) {
      if (i == 90) animation.activity = 'thinking';
      if (i == 180) {
        animation.activity = 'idle';
        animation.custom({
          'expression': 'happy',
          'source': 'streaming-speech',
          'durationMs': 2800,
          'behaviorActions': [
            {'type': 'nod', 'durationMs': 1800},
          ],
        });
      }
      if (i == 250) {
        animation.custom({
          'expression': 'happy',
          'source': 'streaming-speech',
          'durationMs': 2800,
          'behaviorActions': [
            {'type': 'sway', 'durationMs': 2400},
          ],
        });
      }
      if (i == 360) {
        animation.custom({
          'expression': 'happy',
          'durationMs': 1800,
          'behaviorActions': [
            {'type': 'head_tilt', 'durationMs': 1800},
            {'type': 'wink', 'delayMs': 250, 'durationMs': 600},
          ],
          'interruptPolicy': 'replace',
        });
      }
      if (i == 450) {
        animation.custom({
          'expression': 'happy',
          'durationMs': 1800,
          'behaviorActions': [
            {'type': 'bounce', 'durationMs': 1800},
          ],
          'interruptPolicy': 'replace',
        });
      }
      final mouth = i >= 180 && i < 330
          ? math.max(0.0, math.sin(i * .83)) * .6
          : 0.0;
      final timer = Stopwatch()..start();
      animation.advance(1 / 30, mouth: mouth);
      motionMicros.add(timer.elapsedMicroseconds);
      model
        ..studioMotion = animation.usesStudio
        ..parameterOverrides = animation.parameters
        ..parameterWeights = animation.parameterWeights
        ..tick(i / 30, 1 / 30, mouth: mouth);
      if (i.isOdd) continue;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color(0xff151a2c), BlendMode.src);
      canvas.save();
      canvas.translate(0, 90);
      painter.paint(canvas, const Size(480, 630));
      canvas.restore();
      final label = i < 90
          ? '自然待机'
          : i < 180
          ? '思考'
          : i < 330
          ? '说话与连续动作（模拟音量）'
          : i < 360
          ? '说话后的自然停顿'
          : i < 450
          ? '侧头与眨眼'
          : i < 520
          ? '轻快回应'
          : '回到自然待机';
      final text = TextPainter(
        text: TextSpan(
          text: '月读空间 · Studio 动作\n$label',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            height: 1.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 440);
      text.paint(canvas, const Offset(20, 24));
      text.dispose();
      final picture = recorder.endRecording();
      final image = await picture.toImage(480, 720);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '${output.path}/frame-${(i ~/ 2).toString().padLeft(3, '0')}.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    }
    motionMicros.sort();
    final report = {
      'passed': true,
      'frames': 600,
      'renderedFrames': 300,
      'motionP95Ms': motionMicros[(motionMicros.length * .95).floor()] / 1000,
      'meshes': model.meshes.length,
      'engine': 'yachiyo-live2d-studio',
      'sourceCommit': '7cfc08a328be332d3b876a4257e74f8411f08d5f',
      'acceptance': 'native macOS Cubism Canvas; simulated voice; not physical Android validation',
    };
    await File('${output.path}/verification.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    // ignore: avoid_print
    print('STUDIO_NATIVE_RENDER_OK ${jsonEncode(report)}');
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Studio 原生动作验证完成\n600 帧 / 300 张画面\n${output.path}'),
          ),
        ),
      ),
    );
  } catch (error, stack) {
    await File('${output.path}/verification.json').writeAsString(
      jsonEncode({'passed': false, 'error': '$error', 'stack': '$stack'}),
    );
    rethrow;
  } finally {
    painter?.dispose();
    model?.dispose();
    animation.dispose();
  }
}
