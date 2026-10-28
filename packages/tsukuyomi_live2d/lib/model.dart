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
    this.geometryRevision,
    this.staticTopology = false,
  });
  final Float32List positions, uvs;
  final Uint16List indices;
  final int texture, flags;
  int order;
  bool visible;
  double opacity;
  // Native models retain their buffers and advance only changed geometry.
  // Other model implementations use content comparison by default.
  int? geometryRevision;
  final bool staticTopology;
  final List<int> masks;
  final List<double> multiply, screen;
}

abstract class Live2DModel extends ChangeNotifier {
  String? rendererFallbackReason;
  ui.FragmentProgram? get tintProgram => null;
  Map<String, double> parameterOverrides = {};
  Map<String, double> parameterWeights = {};
  bool studioMotion = false;
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
