import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

class LiveMesh {
  LiveMesh({
    required this.positions,
    required this.uvs,
    required this.indices,
    required this.texture,
    required this.order,
    required this.flags,
    required this.visible,
    required this.opacity,
    required this.masks,
    required this.multiply,
    required this.screen,
  });
  final Float32List positions, uvs;
  final Uint16List indices;
  final int texture, order, flags;
  final bool visible;
  final double opacity;
  final List<int> masks;
  final List<double> multiply, screen;
}

abstract class Live2DModel extends ChangeNotifier {
  List<LiveMesh> get meshes;
  List<ui.Image> get textures;
  ui.Rect get bounds;
  List<String> get expressions;
  double get updateMilliseconds;
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  });
}
