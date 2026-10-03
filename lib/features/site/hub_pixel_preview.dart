import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

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

class HubPixelPreview extends StatefulWidget {
  const HubPixelPreview({super.key, required this.artwork});
  final Map<String, dynamic> artwork;

  @override
  State<HubPixelPreview> createState() => _HubPixelPreviewState();
}

class _HubPixelPreviewState extends State<HubPixelPreview> {
  Map<String, dynamic> _source = {};
  ui.Image? _image;
  Color _background = Colors.transparent;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(HubPixelPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Preview responses may be fresh map objects with unchanged pixel data.
    // Compare rendering fields only: changing a title must not decode an image.
    if (_source.entries.any((entry) {
      final next = widget.artwork[entry.key];
      if (entry.value is List && next is List) {
        final before = entry.value as List;
        final limit = entry.key == 'palette' ? 256 : 512 * 512;
        if (before.length != next.length.clamp(0, limit)) return true;
        for (var i = 0; i < before.length; i++) {
          if (before[i] != next[i]) return true;
        }
        return false;
      }
      return entry.value != next;
    })) {
      _decode();
    }
  }

  void _decode() {
    final ticket = ++_revision;
    _source = {
      for (final key in [
        'width',
        'height',
        'size',
        'background_color',
        'backgroundColor',
        'palette',
        'pixels',
        'pixels_base64',
      ])
        key: widget.artwork[key] is List
            ? (widget.artwork[key] as List)
                  .take(key == 'palette' ? 256 : 512 * 512)
                  .toList()
            : widget.artwork[key],
    };
    final data = HubPixelData.fromMap(_source);
    _background = data.background;
    final rgba = Uint8List(data.width * data.height * 4);
    for (var i = 0; i < data.pixels.length; i++) {
      final index = data.pixels[i];
      if (index < 0 || index >= data.palette.length) continue;
      final color = data.palette[index].toARGB32();
      final offset = i * 4;
      rgba[offset] = color >> 16 & 0xff;
      rgba[offset + 1] = color >> 8 & 0xff;
      rgba[offset + 2] = color & 0xff;
      rgba[offset + 3] = color >> 24 & 0xff;
    }
    // Upload one bounded native-resolution texture once. Scrolling then draws
    // one nearest-neighbour image rather than thousands of per-pixel rects.
    ui.decodeImageFromPixels(
      rgba,
      data.width,
      data.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || ticket != _revision) {
          image.dispose();
          return;
        }
        final previous = _image;
        setState(() => _image = image);
        previous?.dispose();
      },
    );
  }

  @override
  void dispose() {
    _revision++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: ColoredBox(
      color: _background,
      child: RawImage(
        image: _image,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.none,
        isAntiAlias: false,
      ),
    ),
  );
}
