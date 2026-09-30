import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'model.dart';

/// Native Flutter triangle renderer. No browser, JavaScript, or platform view.
/// Supports standard Cubism masks, inverted masks, additive/multiply blending,
/// and per-drawable multiply/screen colors. Offscreen part blending is rejected.
class Live2DPainter extends CustomPainter {
  Live2DPainter(this.model) : super(repaint: model);
  final Live2DModel model;
  final _buffers = <int, _MeshBuffer>{};
  List<int> _sorted = [], _orders = [];
  final _layerPaint = Paint();
  final _maskLayerPaint = Paint();

  void dispose() {
    for (final buffer in _buffers.values) {
      buffer.vertices?.dispose();
    }
    _buffers.clear();
    for (final shader in _shaders) {
      shader.dispose();
    }
  }

  late final _shaders = [
    for (final image in model.textures)
      ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        _identity,
        filterQuality: FilterQuality.low,
      ),
  ];
  // A full-character saveLayer for each eyelash/eye mesh is extremely costly.
  // Clip to the actual drawable while retaining a pixel gutter for filtering.
  Rect _meshBounds(LiveMesh mesh, double scale) {
    var left = double.infinity,
        top = double.infinity,
        right = -double.infinity,
        bottom = -double.infinity;
    for (var i = 0; i < mesh.positions.length; i += 2) {
      final x = mesh.positions[i], y = -mesh.positions[i + 1];
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
    return Rect.fromLTRB(left, top, right, bottom).inflate(2 / scale);
  }

  static final _identity = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = model.bounds;
    if (bounds.isEmpty || size.isEmpty || model.meshes.isEmpty) return;
    final scale =
        .94 * (size.width / bounds.width).clamp(0, size.height / bounds.height);
    canvas.save();
    canvas.translate(
      size.width / 2 - bounds.center.dx * scale,
      size.height / 2 - bounds.center.dy * scale,
    );
    canvas.scale(scale);
    if (_orders.length != model.meshes.length) {
      for (final buffer in _buffers.values) {
        buffer.vertices?.dispose();
      }
      _buffers.clear();
      _orders = List.filled(model.meshes.length, -1);
      _sorted = List.generate(model.meshes.length, (i) => i);
    }
    var orderChanged = false;
    for (var i = 0; i < _orders.length; i++) {
      if (_orders[i] != model.meshes[i].order) {
        _orders[i] = model.meshes[i].order;
        orderChanged = true;
      }
    }
    if (orderChanged) {
      _sorted.sort((a, b) {
        final order = _orders[a].compareTo(_orders[b]);
        return order == 0 ? a.compareTo(b) : order;
      });
    }
    for (final i in _sorted) {
      final mesh = model.meshes[i];
      if (!mesh.visible || mesh.opacity <= 0 || mesh.indices.isEmpty) continue;
      final blend = mesh.flags & 1 != 0
          ? BlendMode.plus
          : mesh.flags & 2 != 0
          ? BlendMode.multiply
          : BlendMode.srcOver;
      if (mesh.masks.isEmpty) {
        _draw(canvas, i, mesh, blend);
      } else {
        final clipBounds = _meshBounds(mesh, scale);
        canvas.save();
        canvas.clipRect(clipBounds);
        canvas.saveLayer(clipBounds, _layerPaint..blendMode = blend);
        _draw(canvas, i, mesh, BlendMode.srcOver);
        canvas.saveLayer(
          clipBounds,
          _maskLayerPaint
            ..blendMode = (mesh.flags & 8 != 0
                ? BlendMode.dstOut
                : BlendMode.dstIn),
        );
        for (final mask in mesh.masks) {
          if (mask >= 0 && mask < model.meshes.length) {
            _draw(
              canvas,
              mask,
              model.meshes[mask],
              BlendMode.srcOver,
              mask: true,
            );
          }
        }
        canvas.restore();
        canvas.restore();
        canvas.restore();
      }
    }
    canvas.restore();
  }

  void _draw(
    Canvas canvas,
    int index,
    LiveMesh mesh,
    BlendMode blend, {
    bool mask = false,
  }) {
    if (mesh.texture < 0 ||
        mesh.texture >= model.textures.length ||
        mesh.positions.isEmpty) {
      return;
    }
    final image = model.textures[mesh.texture];
    final buffer = _buffers.putIfAbsent(index, _MeshBuffer.new);
    final vertices = buffer.update(mesh, image.width, image.height);
    final paint = (mask ? buffer.maskPaint : buffer.paint)
      ..isAntiAlias = true
      ..blendMode = blend
      ..color = Colors.white.withValues(alpha: mask ? 1 : mesh.opacity)
      ..shader = _shaders[mesh.texture]
      ..colorFilter = null;
    final m = mesh.multiply, s = mesh.screen;
    // A mask only contributes texture alpha; tinting it white is unnecessary.
    if (!mask &&
        (m[0] != 1 ||
            m[1] != 1 ||
            m[2] != 1 ||
            s[0] != 0 ||
            s[1] != 0 ||
            s[2] != 0)) {
      paint.colorFilter = ColorFilter.matrix([
        m[0] * (1 - s[0]),
        0,
        0,
        0,
        s[0] * 255,
        0,
        m[1] * (1 - s[1]),
        0,
        0,
        s[1] * 255,
        0,
        0,
        m[2] * (1 - s[2]),
        0,
        s[2] * 255,
        0,
        0,
        0,
        1,
        0,
      ]);
    }
    canvas.drawVertices(vertices, BlendMode.srcOver, paint);
  }

  @override
  bool shouldRepaint(covariant Live2DPainter oldDelegate) =>
      oldDelegate.model != model;
}

class _MeshBuffer {
  Float32List positions = Float32List(0), uvs = Float32List(0);
  Uint16List indices = Uint16List(0);
  ui.Vertices? vertices;
  Float32List sourceUvs = Float32List(0);
  int textureWidth = 0, textureHeight = 0;
  final paint = Paint(), maskPaint = Paint();
  ui.Vertices update(LiveMesh mesh, int width, int height) {
    var changed = vertices == null;
    if (positions.length != mesh.positions.length ||
        uvs.length != mesh.uvs.length ||
        indices.length != mesh.indices.length) {
      positions = Float32List(mesh.positions.length);
      uvs = Float32List(mesh.uvs.length);
      indices = Uint16List(mesh.indices.length);
      changed = true;
    }
    for (var i = 0; i < positions.length; i += 2) {
      final x = mesh.positions[i], y = -mesh.positions[i + 1];
      if (positions[i] != x || positions[i + 1] != y) changed = true;
      positions[i] = x;
      positions[i + 1] = y;
    }
    if (sourceUvs.length != mesh.uvs.length) {
      sourceUvs = Float32List(mesh.uvs.length);
      changed = true;
    }
    var uvChanged = textureWidth != width || textureHeight != height;
    for (var i = 0; i < sourceUvs.length; i++) {
      if (sourceUvs[i] != mesh.uvs[i]) uvChanged = true;
      sourceUvs[i] = mesh.uvs[i];
    }
    if (uvChanged) {
      changed = true;
      textureWidth = width;
      textureHeight = height;
      for (var i = 0; i < uvs.length; i += 2) {
        uvs[i] = mesh.uvs[i] * width;
        uvs[i + 1] = (1 - mesh.uvs[i + 1]) * height;
      }
    }
    for (var i = 0; i < indices.length; i++) {
      if (indices[i] != mesh.indices[i]) changed = true;
      indices[i] = mesh.indices[i];
    }
    if (changed) {
      vertices?.dispose();
      vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: uvs,
        indices: indices,
      );
    }
    return vertices!;
  }
}
