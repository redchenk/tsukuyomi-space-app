import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kaguya_runtime.dart';

class KaguyaAssets {
  KaguyaAssets(this.project, this.masks, this.images, this.effects);
  final Map<String, dynamic> project;
  final Uint8List masks;
  final Map<String, ui.Image> images;
  final ui.FragmentProgram effects;
  static const pixelFont = 'KaguyaPixel';
  static Future<void>? _fontLoad;

  static Future<void> _loadFont(AssetBundle bundle) async {
    try {
      final loader = FontLoader(pixelFont)
        ..addFont(
          bundle.load('assets/game/3775f951f15adf0c99bad299fbebefbc.ttf'),
        );
      await loader.load();
    } catch (_) {
      _fontLoad = null;
      rethrow;
    }
  }

  static Future<KaguyaAssets> load({AssetBundle? bundle}) async {
    final source = bundle ?? rootBundle;
    await (_fontLoad ??= _loadFont(source));
    final project = jsonDecode(
      await source.loadString('assets/game/project.json'),
    ) as Map<String, dynamic>;
    final masks = (await source.load('assets/game/masks.bin')).buffer
        .asUint8List();
    final images = <String, ui.Image>{};
    try {
      // Bound decoding concurrency: the original project includes large skies.
      final files = <String>{
        for (final target in project['targets'] as List)
          for (final costume in target['costumes'] as List)
            '${costume['file']}',
      }.toList();
      for (var start = 0; start < files.length; start += 6) {
        await Future.wait(
          files.skip(start).take(6).map((file) async {
            final bytes = (await source.load('assets/game/$file')).buffer
                .asUint8List();
            final codec = await ui.instantiateImageCodec(bytes);
            try {
              images[file] = (await codec.getNextFrame()).image;
            } finally {
              codec.dispose();
            }
          }),
        );
      }
      final effects = await ui.FragmentProgram.fromAsset(
        'assets/shaders/kaguya_effect.frag',
      );
      return KaguyaAssets(project, masks, images, effects);
    } catch (_) {
      for (final image in images.values) {
        image.dispose();
      }
      rethrow;
    }
  }

  KaguyaRuntime runtime({math.Random? random}) =>
      KaguyaRuntime(project, random: random)..setMasks(masks);
  void dispose() {
    for (final image in images.values) {
      image.dispose();
    }
  }
}

class KaguyaPainter extends CustomPainter {
  KaguyaPainter(this.runtime, this.assets) : super(repaint: runtime);
  final KaguyaRuntime runtime;
  final KaguyaAssets assets;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 480, size.height / 360);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 480, 360));
    canvas.drawColor(Colors.white, BlendMode.src);
    final sprites =
        runtime.sprites.where((s) => s.visible && !s.deleted).toList()..sort(
          (a, b) => a.isStage
              ? -1
              : b.isStage
              ? 1
              : a.layer.compareTo(b.layer),
        );
    for (final sprite in sprites) {
      final opacity = (1 - (sprite.effects['ghost'] ?? 0).clamp(0, 100) / 100);
      if (opacity <= 0) continue;
      canvas.save();
      canvas.translate(240 + sprite.x, 180 - sprite.y);
      canvas.rotate(sprite.angle);
      canvas.scale(sprite.scaleX, sprite.scaleY);
      if (sprite.text.isNotEmpty) {
        _text(canvas, sprite, opacity);
      } else {
        final costume = sprite.currentCostume;
        final image = assets.images[costume['file']];
        if (image != null) {
          final resolution = KaguyaRuntime.number(
            costume['bitmapResolution'] ?? 1,
          );
          canvas.scale(1 / resolution);
          final origin = Offset(
            -KaguyaRuntime.number(costume['rotationCenterX']),
            -KaguyaRuntime.number(costume['rotationCenterY']),
          );
          if (sprite.effects.isEmpty) {
            canvas.drawImage(
              image,
              origin,
              Paint()..filterQuality = FilterQuality.low,
            );
          } else {
            final shader = assets.effects.fragmentShader()
              ..setFloat(0, image.width.toDouble())
              ..setFloat(1, image.height.toDouble())
              ..setFloat(2, origin.dx)
              ..setFloat(3, origin.dy)
              ..setFloat(4, ((sprite.effects['color'] ?? 0) % 200) / 200)
              ..setFloat(
                5,
                (sprite.effects['brightness'] ?? 0).clamp(-100, 100) / 100,
              )
              ..setFloat(6, opacity)
              ..setImageSampler(0, image);
            canvas.drawRect(
              origin & Size(image.width.toDouble(), image.height.toDouble()),
              Paint()..shader = shader,
            );
            shader.dispose();
          }
        }
      }
      canvas.restore();
    }
    canvas.restore();
  }

  void _text(Canvas canvas, KaguyaSprite s, double opacity) {
    Color color(String hex) =>
        Color(int.tryParse(hex.replaceFirst('#', ''), radix: 16)! | 0xff000000)
            .withValues(alpha: opacity);
    final shown = s.displayedText(runtime.time);
    final family = s.font.contains('HYPixel11pxU-2')
        ? KaguyaAssets.pixelFont
        : null;
    final width = s.textWidth / s.scaleX.abs().clamp(.001, double.infinity);
    final text = TextPainter(
      text: TextSpan(
        text: shown,
        style: TextStyle(
          fontSize: s.fontSize,
          fontFamily: family,
          color: color(s.textColor),
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width);
    // The original text skin anchors 0.9 em below the first line's top;
    // canvas paints the baseline at 1 em, independent of the outline padding.
    final baseline = text.computeLineMetrics().firstOrNull?.baseline ?? 0;
    final offset = Offset(-text.width / 2, s.fontSize * .1 - baseline);
    if (s.isTextShaking(runtime.time) && s.shake > 0) {
      canvas.translate(
        math.sin(runtime.time * 97) * s.shake / 20,
        math.cos(runtime.time * 83) * s.shake / 20,
      );
    }
    if (s.outlineWidth > 0) {
      final outline = TextPainter(
        text: TextSpan(
          text: shown,
          style: TextStyle(
            fontSize: s.fontSize,
            fontFamily: family,
            foreground: Paint()
              ..color = color(s.outlineColor)
              ..style = PaintingStyle.stroke
              ..strokeWidth = s.outlineWidth,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: width);
      outline.paint(canvas, offset);
    }
    text.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(KaguyaPainter oldDelegate) =>
      oldDelegate.runtime != runtime || oldDelegate.assets != assets;
}
