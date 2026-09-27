import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

// Run this release entrypoint on devices, not only with the host test runner.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final model = await loadLive2D();
    if (model.meshes.length < 10 || model.textures.isEmpty) {
      throw StateError('Cubism returned an empty model');
    }
    runApp(
      MaterialApp(
        home: Scaffold(
          body: CustomPaint(
            painter: Live2DPainter(model),
            size: const Size(390, 800),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    for (var i = 0; i < 120; i++) {
      model.tick(i / 60, 1 / 60, mouth: (i % 30) / 30);
      await Future<void>.delayed(const Duration(milliseconds: 17));
    }
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_OK meshes=${model.meshes.length} textures=${model.textures.length}',
    );
  } catch (e, st) {
    // ignore: avoid_print
    print('TSUKUYOMI_LIVE2D_FAILED $e\n$st');
    exit(1);
  }
}
