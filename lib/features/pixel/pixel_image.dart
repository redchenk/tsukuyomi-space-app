import 'dart:ui' as ui;
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import 'pixel_document.dart';

Color pixelColor(String value) =>
    Color(0xff000000 | int.parse(pixelHex(value).substring(1), radix: 16));

class PixelPainter extends CustomPainter {
  PixelPainter(this.snapshot, {this.grid = false});
  final PixelSnapshot snapshot;
  final bool grid;
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / snapshot.width, sy = size.height / snapshot.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = pixelColor(snapshot.background),
    );
    final paint = Paint()..isAntiAlias = false;
    for (var i = 0; i < snapshot.pixels.length; i++) {
      final index = snapshot.pixels[i];
      if (index < 0 || index >= snapshot.palette.length) continue;
      paint.color = pixelColor(snapshot.palette[index]);
      canvas.drawRect(
        Rect.fromLTWH(
          (i % snapshot.width) * sx,
          (i ~/ snapshot.width) * sy,
          sx,
          sy,
        ),
        paint,
      );
    }
    if (grid && sx >= 4) {
      paint
        ..color = const Color(0x1514262d)
        ..strokeWidth = .5;
      for (var x = 1; x < snapshot.width; x++) {
        canvas.drawLine(Offset(x * sx, 0), Offset(x * sx, size.height), paint);
      }
      for (var y = 1; y < snapshot.height; y++) {
        canvas.drawLine(Offset(0, y * sy), Offset(size.width, y * sy), paint);
      }
    }
  }

  @override
  bool shouldRepaint(PixelPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot || oldDelegate.grid != grid;
}

Future<Uint8List> pixelPng(PixelSnapshot snapshot, {int cellSize = 8}) async {
  final recorder = ui.PictureRecorder();
  PixelPainter(snapshot).paint(
    Canvas(recorder),
    Size(
      (snapshot.width * cellSize).toDouble(),
      (snapshot.height * cellSize).toDouble(),
    ),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    snapshot.width * cellSize,
    snapshot.height * cellSize,
  );
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw const ApiFailure('图片导出失败');
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> pixelImageRgba(Uint8List bytes, int width, int height) async {
  if (bytes.length > 20 * 1024 * 1024) throw const ApiFailure('图片不能超过 20 MB');
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    if (descriptor.width * descriptor.height > 100000000) {
      throw const ApiFailure('图片尺寸过大');
    }
    final factor = math.min(
      1.0,
      2048 / math.max(descriptor.width, descriptor.height),
    );
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * factor).round().clamp(1, 2048),
      targetHeight: (descriptor.height * factor).round().clamp(1, 2048),
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final recorder = ui.PictureRecorder(),
        paint = Paint()..filterQuality = FilterQuality.high;
    final image = frame.image;
    final aspect = width / height, sourceAspect = image.width / image.height;
    final cropW = sourceAspect > aspect
        ? image.height * aspect
        : image.width.toDouble();
    final cropH = sourceAspect > aspect
        ? image.height.toDouble()
        : image.width / aspect;
    Canvas(recorder).drawImageRect(
      image,
      Rect.fromLTWH(
        (image.width - cropW) / 2,
        (image.height - cropH) / 2,
        cropW,
        cropH,
      ),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      paint,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(width, height);
    try {
      final data = await resized.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw const ApiFailure('图片转换失败');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      resized.dispose();
      picture.dispose();
      image.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}
