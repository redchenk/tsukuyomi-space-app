import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../core/models.dart';

enum PixelTool { brush, eraser, fill, move }

const pixelPresetPalette = [
  '#0b1020',
  '#ffffff',
  '#aef2ff',
  '#7b8cf6',
  '#a481ff',
  '#ff9aba',
  '#f1d98e',
  '#9ee2cf',
  '#263044',
  '#e85f9b',
  '#56bfe8',
  '#647086',
];
const pixelCanvasPresets = [
  (32, 18),
  (48, 27),
  (64, 36),
  (96, 54),
  (128, 72),
  (160, 90),
  (192, 108),
];

String pixelHex(dynamic value, [String fallback = '#0b1020']) {
  final text = '$value'.trim().toLowerCase();
  return RegExp(r'^#[0-9a-f]{6}$').hasMatch(text) ? text : fallback;
}

class PixelSnapshot {
  PixelSnapshot({
    required this.width,
    required this.height,
    required List<int> pixels,
    required List<String> palette,
    required this.background,
  }) : pixels = List.unmodifiable(pixels),
       palette = List.unmodifiable(palette);
  final int width, height;
  final List<int> pixels;
  final List<String> palette;
  final String background;
  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'pixels': pixels,
    'palette': palette,
    'background_color': background,
  };
  factory PixelSnapshot.fromJson(Map<String, dynamic> value) {
    final width = int.tryParse('${value['width'] ?? value['size']}') ?? 192;
    final height = int.tryParse('${value['height'] ?? value['size']}') ?? 108;
    if (!pixelCanvasPresets.contains((width, height))) {
      throw const ApiFailure('画布尺寸不兼容');
    }
    final colors = value['palette'];
    if (colors is! List ||
        colors.length < 2 ||
        colors.length > 64 ||
        colors.any(
          (color) => !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch('$color'),
        )) {
      throw const ApiFailure('调色板格式不正确');
    }
    final cells = value['pixels'];
    if (cells is! List ||
        cells.length != width * height ||
        cells.any(
          (cell) => cell is! int || cell < -1 || cell >= colors.length,
        )) {
      throw const ApiFailure('像素数据格式不正确');
    }
    return PixelSnapshot(
      width: width,
      height: height,
      pixels: cells.cast<int>(),
      palette: colors.map(pixelHex).toList(),
      background: pixelHex(
        value['background_color'] ?? value['backgroundColor'],
        '#ffffff',
      ),
    );
  }
}

/// A palette-index document: -1 is transparent, matching the website contract.
class PixelDocument extends ChangeNotifier {
  int width = 192, height = 108, brushSize = 1, selected = 3;
  List<int> pixels = List.filled(192 * 108, -1);
  List<String> palette = List.of(pixelPresetPalette);
  String background = '#ffffff';
  PixelTool tool = PixelTool.brush;
  bool pressureEnabled = true, stabilizerEnabled = true;
  int revision = 0;
  final _undo = <PixelSnapshot>[], _redo = <PixelSnapshot>[];
  bool _drawing = false;
  (double, double)? _lastPoint;
  int _paintColor = -1;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get paintedCount => pixels.where((value) => value >= 0).length;
  PixelSnapshot get snapshot => PixelSnapshot(
    width: width,
    height: height,
    pixels: pixels,
    palette: palette,
    background: background,
  );
  void _changed() {
    revision++;
    notifyListeners();
  }

  void _pushHistory() {
    _undo.add(snapshot);
    if (_undo.length > 50) _undo.removeAt(0);
    _redo.clear();
  }

  void load(PixelSnapshot value, {bool history = false}) {
    endStroke();
    if (history) {
      _pushHistory();
    } else {
      _undo.clear();
      _redo.clear();
    }
    _restore(value);
    _changed();
  }

  void _restore(PixelSnapshot value) {
    width = value.width;
    height = value.height;
    pixels = List.of(value.pixels);
    palette = List.of(value.palette);
    background = value.background;
    selected = selected.clamp(0, palette.length - 1);
  }

  void resize(int nextWidth, int nextHeight) {
    if (!pixelCanvasPresets.contains((nextWidth, nextHeight))) return;
    _pushHistory();
    final next = List.filled(nextWidth * nextHeight, -1);
    for (var y = 0; y < nextHeight; y++) {
      for (var x = 0; x < nextWidth; x++) {
        next[y * nextWidth + x] =
            pixels[(y * height ~/ nextHeight) * width + x * width ~/ nextWidth];
      }
    }
    pixels = next;
    width = nextWidth;
    height = nextHeight;
    _changed();
  }

  void chooseTool(PixelTool value) {
    tool = value;
    notifyListeners();
  }

  void chooseColor(int value) {
    if (value >= 0 && value < palette.length) {
      selected = value;
      notifyListeners();
    }
  }

  int addColor(String value) {
    final color = pixelHex(value);
    final existing = palette.indexOf(color);
    if (existing >= 0) {
      chooseColor(existing);
      return existing;
    }
    if (palette.length >= 64) throw const ApiFailure('64 色调色板已满');
    palette = [...palette, color];
    selected = palette.length - 1;
    _changed();
    return selected;
  }

  void setBackground(String value) {
    final color = pixelHex(value, '#ffffff');
    if (color == background) return;
    _pushHistory();
    background = color;
    _changed();
  }

  void undo() {
    endStroke();
    if (_undo.isEmpty) return;
    _redo.add(snapshot);
    _restore(_undo.removeLast());
    _changed();
  }

  void redo() {
    endStroke();
    if (_redo.isEmpty) return;
    _undo.add(snapshot);
    _restore(_redo.removeLast());
    _changed();
  }

  void clear() {
    endStroke();
    _pushHistory();
    pixels = List.filled(width * height, -1);
    _changed();
  }

  void beginStroke(
    double x,
    double y, {
    double pressure = .5,
    bool pen = false,
  }) {
    if (tool == PixelTool.move) return;
    final index = cellIndex(x, y);
    if (index == null) return;
    _pushHistory();
    _paintColor = tool == PixelTool.eraser ? -1 : selected;
    if (tool == PixelTool.fill) {
      _fill(index, _paintColor);
      _changed();
      return;
    }
    _drawing = true;
    _lastPoint = (x, y);
    _stamp(x.floor(), y.floor(), pressure, pen);
    _changed();
  }

  void continueStroke(
    double x,
    double y, {
    double pressure = .5,
    bool pen = false,
  }) {
    if (!_drawing || _lastPoint == null) return;
    final (lastX, lastY) = _lastPoint!;
    if (stabilizerEnabled && pen) {
      x = lastX + (x - lastX) * .62;
      y = lastY + (y - lastY) * .62;
    }
    var a = lastX.floor(), b = lastY.floor();
    final endX = x.floor(), endY = y.floor();
    final dx = (endX - a).abs(), dy = -(endY - b).abs();
    final sx = a < endX ? 1 : -1, sy = b < endY ? 1 : -1;
    var error = dx + dy;
    while (true) {
      _stamp(a, b, pressure, pen);
      if (a == endX && b == endY) break;
      final e = error * 2;
      if (e >= dy) {
        error += dy;
        a += sx;
      }
      if (e <= dx) {
        error += dx;
        b += sy;
      }
    }
    _lastPoint = (x, y);
    _changed();
  }

  void endStroke() {
    _drawing = false;
    _lastPoint = null;
  }

  int? cellIndex(double x, double y) =>
      x < 0 || y < 0 || x >= width || y >= height
      ? null
      : y.floor() * width + x.floor();
  void _stamp(int x, int y, double pressure, bool pen) {
    var diameter = brushSize.clamp(1, 6);
    if (pressureEnabled && pen) {
      diameter =
          (diameter +
                  math.max(0, ((pressure.clamp(0.0, 1.0) - .45) * 3).round()))
              .clamp(1, 6)
              .toInt();
    }
    final start = (diameter - 1) ~/ 2;
    for (var dy = 0; dy < diameter; dy++) {
      for (var dx = 0; dx < diameter; dx++) {
        final px = x + dx - start, py = y + dy - start;
        if (px >= 0 && py >= 0 && px < width && py < height) {
          pixels[py * width + px] = _paintColor;
        }
      }
    }
  }

  void _fill(int index, int color) {
    final old = pixels[index];
    if (old == color) return;
    final queue = [index];
    pixels[index] = color;
    while (queue.isNotEmpty) {
      final current = queue.removeLast(),
          x = current % width,
          y = current ~/ width;
      for (final next in [
        if (x > 0) current - 1,
        if (x < width - 1) current + 1,
        if (y > 0) current - width,
        if (y < height - 1) current + width,
      ]) {
        if (pixels[next] == old) {
          pixels[next] = color;
          queue.add(next);
        }
      }
    }
  }

  void moonExample() {
    _pushHistory();
    pixels = List.filled(width * height, -1);
    final cx = width * .5, cy = height * .5, radius = height * .33;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius &&
            (x - cx - radius * .5) * (x - cx - radius * .5) +
                    (y - cy + radius * .3) * (y - cy + radius * .3) >
                radius * radius) {
          pixels[y * width + x] = 6;
        }
      }
    }
    background = '#0b1020';
    _changed();
  }

  /// Quantization matches the site's 32-channel-step image conversion.
  void importRgba(Uint8List bytes) {
    if (bytes.length != width * height * 4) throw const ApiFailure('图片转换尺寸不正确');
    _pushHistory();
    final colors = <String?>[], counts = <String, int>{};
    final bg = int.parse(background.substring(1), radix: 16);
    for (var i = 0; i < bytes.length; i += 4) {
      final alpha = bytes[i + 3] / 255;
      if (bytes[i + 3] < 24) {
        colors.add(null);
        continue;
      }
      final channels = [
        for (var channel = 0; channel < 3; channel++)
          ((((bytes[i + channel] * alpha +
                                  ((bg >> (16 - channel * 8)) & 255) *
                                      (1 - alpha))
                              .round() /
                          32)
                      .round() *
                  32)
              .clamp(0, 255)),
      ];
      final color =
          '#${channels.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
      colors.add(color);
      counts[color] = (counts[color] ?? 0) + 1;
    }
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    palette = [
      ...pixelPresetPalette,
      ...ranked
          .take(32)
          .map((e) => e.key)
          .where((c) => !pixelPresetPalette.contains(c)),
    ];
    pixels = colors
        .map((c) => c == null ? -1 : nearestPalette(c, palette))
        .toList();
    selected = ranked.isEmpty ? 3 : nearestPalette(ranked.first.key, palette);
    _changed();
  }

  static int nearestPalette(String color, List<String> palette) {
    final value = int.parse(color.substring(1), radix: 16);
    var best = 0, distance = 1 << 30;
    for (var i = 0; i < palette.length; i++) {
      final next = int.parse(palette[i].substring(1), radix: 16);
      var sum = 0;
      for (final shift in [16, 8, 0]) {
        final delta = ((value >> shift) & 255) - ((next >> shift) & 255);
        sum += delta * delta;
      }
      if (sum < distance) {
        distance = sum;
        best = i;
      }
    }
    return best;
  }
}
