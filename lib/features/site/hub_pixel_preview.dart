import 'dart:convert';

import 'package:flutter/material.dart';

/// The website preview encodes a palette index as one byte plus one. Zero is
/// transparent, so decoding must keep it as -1 rather than a palette colour.
class HubPixelData {
  HubPixelData.fromMap(Map<String, dynamic> artwork)
    : width = _dimension(artwork['width'] ?? artwork['size'], 96),
      height = _dimension(artwork['height'] ?? artwork['size'], 54),
      background = _colour(
        artwork['background_color'] ?? artwork['backgroundColor'],
        const Color(0xff0b1020),
      ),
      palette = _palette(artwork['palette']) {
    final limit = width * height;
    if (artwork['pixels'] is List) {
      pixels = (artwork['pixels'] as List)
          .take(limit)
          .map((value) => value is num ? value.toInt() : -1)
          .toList();
    } else {
      try {
        final encoded = artwork['pixels_base64'];
        pixels = encoded is String && encoded.length <= 350000
            ? base64Decode(encoded)
                  .take(limit)
                  .map((value) => value - 1)
                  .toList()
            : [];
      } catch (_) {
        pixels = [];
      }
    }
  }

  final int width, height;
  final Color background;
  final List<Color> palette;
  late final List<int> pixels;

  static int _dimension(dynamic value, int fallback) {
    final parsed = int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed.clamp(1, 512) : fallback;
  }

  static Color _colour(dynamic value, Color fallback) {
    var hex = '$value'.replaceFirst('#', '');
    if (hex.length == 3) {
      hex = hex.split('').map((value) => '$value$value').join();
    }
    if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(hex)) {
      return fallback;
    }
    if (hex.length == 8) hex = '${hex.substring(6)}${hex.substring(0, 6)}';
    return Color(int.parse(hex.length == 6 ? 'ff$hex' : hex, radix: 16));
  }

  static List<Color> _palette(dynamic value) =>
      value is List && value.isNotEmpty
      ? value
            .take(256)
            .map((value) => _colour(value, Colors.transparent))
            .toList()
      : const [
          Color(0xff0b1020),
          Colors.white,
          Color(0xffaef2ff),
          Color(0xff7b8cf6),
          Color(0xffff9aba),
          Color(0xfff1d98e),
        ];
}

class HubPixelPreview extends StatelessWidget {
  const HubPixelPreview({super.key, required this.artwork});
  final Map<String, dynamic> artwork;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _HubPixelPainter(HubPixelData.fromMap(artwork)),
    child: const SizedBox.expand(),
  );
}

class _HubPixelPainter extends CustomPainter {
  _HubPixelPainter(this.data);
  final HubPixelData data;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(data.background, BlendMode.src);
    final scale = (size.width / data.width) < (size.height / data.height)
        ? size.width / data.width
        : size.height / data.height;
    final origin = Offset(
      (size.width - data.width * scale) / 2,
      (size.height - data.height * scale) / 2,
    );
    final paint = Paint()..isAntiAlias = false;
    for (var i = 0; i < data.pixels.length; i++) {
      final index = data.pixels[i];
      if (index < 0 || index >= data.palette.length) continue;
      paint.color = data.palette[index];
      canvas.drawRect(
        Rect.fromLTWH(
          origin.dx + (i % data.width) * scale,
          origin.dy + (i ~/ data.width) * scale,
          scale,
          scale,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HubPixelPainter oldDelegate) => oldDelegate.data != data;
}
