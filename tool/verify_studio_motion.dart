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
  const fps = 60, seconds = 20, seed = 919;
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
      seed: seed,
    );
    animation.ready = true;
    model = await loadLive2D(maxTextureSize: 3072, renderer: 'canvas');
    painter = Live2DPainter(model)..pixelRatio = 1;
    final motionMicros = <int>[];
    final trajectory = <Map<String, dynamic>>[];
    for (var i = 0; i < fps * seconds; i++) {
      final t = i / fps;
      if (i == 3 * fps) animation.activity = 'thinking';
      if (i == 6 * fps) {
        animation.activity = 'idle';
        animation.react('这件事我们可以接着聊。', speaking: true);
      }
      if (i == 9 * fps) {
        animation.react('我就在这里。', speaking: true);
      }
      if (i == 12 * fps) {
        animation.custom({
          'expression': 'neutral',
          'durationMs': 2400,
          'behaviorActions': [
            {
              'type': 'head_tilt',
              'side': 'right',
              'intensity': .8,
              'durationMs': 2200,
            },
            {'type': 'wink', 'delayMs': 600, 'durationMs': 650},
          ],
          'interruptPolicy': 'replace',
        });
      }
      if (i == 15 * fps) {
        animation.custom({
          'expression': 'smug',
          'durationMs': 2400,
          'behaviorActions': [
            {'type': 'sway', 'intensity': .75, 'durationMs': 2200},
            {'type': 'ear_perk', 'delayMs': 450, 'durationMs': 1000},
          ],
          'interruptPolicy': 'replace',
        });
      }
      final mouth = t >= 6 && t < 11.6
          ? math.max(0.0, math.sin(t * 24.9)) *
                .6 *
                (.65 + .35 * math.sin(t * 2.7).abs())
          : 0.0;
      final timer = Stopwatch()..start();
      animation.advance(1 / fps, mouth: mouth);
      motionMicros.add(timer.elapsedMicroseconds);
      trajectory.add({
        't': t,
        'p': Map.of(animation.parameters),
        'w': Map.of(animation.parameterWeights),
      });
      model
        ..studioMotion = animation.usesStudio
        ..parameterOverrides = animation.parameters
        ..parameterWeights = animation.parameterWeights
        ..tick(t, 1 / fps, mouth: mouth);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color(0xff151a2c), BlendMode.src);
      canvas.save();
      canvas.translate(0, 90);
      painter.paint(canvas, const Size(480, 630));
      canvas.restore();
      final label = t < 3
          ? '自然待机'
          : t < 6
          ? '思考'
          : t < 12
          ? '交流与小动作 · 模拟语音'
          : t < 15
          ? '侧头与俏皮眨眼'
          : t < 17.5
          ? '轻摆与耳朵回应'
          : '回到自然待机';
      final text = TextPainter(
        text: TextSpan(
          text: '月读空间 · Studio 动作 · 60 fps\n$label',
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
      await File('${output.path}/frame-${i.toString().padLeft(4, '0')}.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    }
    motionMicros.sort();
    final report = {
      'passed': true,
      'frames': fps * seconds,
      'renderedFrames': fps * seconds,
      'fps': fps,
      'seconds': seconds,
      'seed': seed,
      'interpolatedFrames': 0,
      'motionP95Ms': motionMicros[(motionMicros.length * .95).floor()] / 1000,
      'meshes': model.meshes.length,
      'engine': 'yachiyo-live2d-studio',
      'sourceCommit': '7cfc08a328be332d3b876a4257e74f8411f08d5f',
      'acceptance': 'native macOS Cubism Canvas; simulated voice; not physical Android validation',
    };
    await File('${output.path}/verification.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    await File('${output.path}/trajectory.json')
        .writeAsString(jsonEncode(trajectory));
    // ignore: avoid_print
    print('STUDIO_NATIVE_RENDER_OK ${jsonEncode(report)}');
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text('Studio 原生动作验证完成\n1200 帧 / 60 fps\n${output.path}'),
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
