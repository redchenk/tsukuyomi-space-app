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
    final sorted = List<int>.generate(model.meshes.length, (i) => i)
      ..sort((a, b) => model.meshes[a].order.compareTo(model.meshes[b].order));
    for (final i in sorted) {
      final mesh = model.meshes[i];
      if (!mesh.visible || mesh.opacity <= 0 || mesh.indices.isEmpty) continue;
      final blend = mesh.flags & 1 != 0
          ? BlendMode.plus
          : mesh.flags & 2 != 0
          ? BlendMode.multiply
          : BlendMode.srcOver;
      if (mesh.masks.isEmpty) {
        _draw(canvas, mesh, blend);
      } else {
        final clipBounds = _meshBounds(mesh, scale);
        canvas.save();
        canvas.clipRect(clipBounds);
        canvas.saveLayer(clipBounds, Paint()..blendMode = blend);
        _draw(canvas, mesh, BlendMode.srcOver);
        canvas.saveLayer(
          clipBounds,
          Paint()
            ..blendMode = (mesh.flags & 8 != 0
                ? BlendMode.dstOut
                : BlendMode.dstIn),
        );
        for (final mask in mesh.masks) {
          if (mask >= 0 && mask < model.meshes.length) {
            _draw(canvas, model.meshes[mask], BlendMode.srcOver, mask: true);
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
    final positions = Float32List(mesh.positions.length);
    final uvs = Float32List(mesh.uvs.length);
    for (var i = 0; i < positions.length; i += 2) {
      positions[i] = mesh.positions[i];
      positions[i + 1] = -mesh.positions[i + 1];
      uvs[i] = mesh.uvs[i] * image.width;
      uvs[i + 1] = (1 - mesh.uvs[i + 1]) * image.height;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: uvs,
      indices: mesh.indices,
    );
    final paint = Paint()
      ..isAntiAlias = true
      ..blendMode = blend
      // Keep drawable opacity separate from the RGB color transform. In the
      // Metal vertices path, alpha inside a matrix color filter can produce
      // over-bright additive eye highlights as their opacity animates.
      ..color = Colors.white.withValues(alpha: mask ? 1 : mesh.opacity)
      ..shader = _shaders[mesh.texture];
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
    vertices.dispose();
  }

  @override
  bool shouldRepaint(covariant Live2DPainter oldDelegate) =>
      oldDelegate.model != model;
}
