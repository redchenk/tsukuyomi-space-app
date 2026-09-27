import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

class _ProbeModel extends Live2DModel {
  _ProbeModel(this.textures, this.meshes);
  @override
  final List<ui.Image> textures;
  @override
  final List<LiveMesh> meshes;
  @override
  Rect get bounds => const Rect.fromLTRB(0, -10, 10, 0);
  @override
  List<String> get expressions => [];
  @override
  double get updateMilliseconds => 0;
  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {}
}

/// Pixel expectations work in flutter_tester and in a native GPU probe.
Future<Map<String, List<int>>> probeLive2DOpacity() async {
  final textureRecorder = ui.PictureRecorder();
  Canvas(textureRecorder).drawColor(Colors.white, BlendMode.src);
  final texturePicture = textureRecorder.endRecording();
  final texture = await texturePicture.toImage(8, 8);
  texturePicture.dispose();
  LiveMesh mesh({
    int flags = 4,
    double opacity = .25,
    bool mask = false,
    bool clipped = false,
  }) => LiveMesh(
    positions: Float32List.fromList([0, 0, 10, 0, 10, 10, 0, 10]),
    uvs: Float32List.fromList([0, 0, 1, 0, 1, 1, 0, 1]),
    indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
    texture: 0,
    order: mask ? 0 : 1,
    flags: flags,
    visible: !mask,
    opacity: mask ? 0 : opacity,
    masks: clipped ? [0] : [],
    multiply: [1, 1, 1, 1],
    screen: [0, 0, 0, 0],
  );
  final result = <String, List<int>>{};
  try {
    for (final entry in {
      'normal': 4,
      'additive': 5,
      'masked additive': 5,
    }.entries) {
      final clipped = entry.key.startsWith('masked');
      final model = _ProbeModel(
        [texture],
        [
          if (clipped) mesh(mask: true),
          mesh(flags: entry.value, clipped: clipped),
        ],
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color.fromARGB(255, 20, 30, 60), BlendMode.src);
      Live2DPainter(model).paint(canvas, const Size(32, 32));
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      result[entry.key] = List.generate(
        4,
        (i) => bytes.getUint8((16 * 32 + 16) * 4 + i),
      );
      image.dispose();
      picture.dispose();
      model.dispose();
    }
  } finally {
    texture.dispose();
  }
  return result;
}

const expectedLive2DOpacity = <String, List<int>>{
  'normal': [79, 86, 109, 255],
  'additive': [84, 94, 124, 255],
  'masked additive': [84, 94, 124, 255],
};
