import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'animation_parameters.dart';
import 'model.dart';

const _channel = MethodChannel('space.tsukuyomi/live2d_gpu');

/// Cubism native GPU renderer. Atlases cross the channel once at load time;
/// animation frames contain only one ordered parameter batch and output size.
class GpuLive2DModel extends Live2DModel {
  static final _models = <int, GpuLive2DModel>{};
  static Future<void> _nativeEvent(MethodCall call) async {
    if (call.method == 'surfaceAvailable') {
      _models[(call.arguments as Map)['id']]?._refreshSurface();
    }
  }

  void _refreshSurface() {
    if (_disposed || failure != null || width == 0 || height == 0) return;
    if (_pending) {
      _resizePending = true;
    } else if (_parameters.isNotEmpty) {
      _submit(0);
    }
  }

  GpuLive2DModel._(Map<dynamic, dynamic> info, this._expressions)
    : textureId = info['textureId'] as int,
      backend = info['backend'] as String? ?? 'OpenGL ES',
      meshCount = info['meshCount'] as int,
      maxSize = info['maxSize'] as int,
      atlasBytes = info['atlasBytes'] as int,
      bounds = ui.Rect.fromLTRB(
        (info['bounds'][0] as num).toDouble(),
        (info['bounds'][1] as num).toDouble(),
        (info['bounds'][2] as num).toDouble(),
        (info['bounds'][3] as num).toDouble(),
      );

  static Future<GpuLive2DModel> load({
    required String manifest,
    required int maxTextureSize,
    int nativeApiAddress = 0,
    bool decodeAtlases = false,
  }) async {
    final watch = Stopwatch()..start();
    _channel.setMethodCallHandler(_nativeEvent);
    final json = jsonDecode(await rootBundle.loadString(manifest)) as Map;
    final refs = json['FileReferences'] as Map;
    final base = Uri.parse(manifest).resolve('.');
    String asset(String path) {
      final uri = base.resolve(path);
      if (uri.hasScheme ||
          !uri.path.startsWith(base.path) ||
          path.startsWith('/')) {
        throw const FormatException('Invalid Live2D asset path');
      }
      return uri.toString();
    }

    Future<Uint8List> bytes(String path) async {
      final data = await rootBundle.load(asset(path));
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    // Independent bundle reads must not serialize each expression and atlas.
    // Await everything before creating a native scene, including error paths.
    final (moc, physics, textures, expressionEntries) = await (
      bytes(refs['Moc'] as String),
      refs['Physics'] is String
          ? bytes(refs['Physics'] as String)
          : Future.value(Uint8List(0)),
      Future.wait(
        (refs['Textures'] as List).map((path) => bytes(path as String)),
      ),
      Future.wait(
        (refs['Expressions'] as List? ?? []).map((entry) async {
          final value = jsonDecode(
            await rootBundle.loadString(asset(entry['File'] as String)),
          ) as Map;
          return MapEntry(
            entry['Name'] as String,
            (value['Parameters'] as List)
                .cast<Map>()
                .map((v) => Map<String, dynamic>.from(v))
                .toList(),
          );
        }),
      ),
    ).wait;
    final assetMilliseconds = watch.elapsedMicroseconds / 1000;
    // Desktop system codecs do not consistently include WebP. Decode once
    // using Flutter's bundled codecs; no atlas pixels cross Dart per frame.
    final atlases = <Map<String, Object>>[];
    if (decodeAtlases) {
      final limit = maxTextureSize == 0 ? 4096 : math.min(maxTextureSize, 4096);
      for (final encoded in textures) {
        final codec = await ui.instantiateImageCodecWithSize(
          await ui.ImmutableBuffer.fromUint8List(encoded),
          getTargetSize: (w, h) {
            final scale = math.min(1.0, limit / math.max(w, h));
            return ui.TargetImageSize(
              width: math.max(1, (w * scale).round()),
              height: math.max(1, (h * scale).round()),
            );
          },
        );
        try {
          final image = (await codec.getNextFrame()).image;
          try {
            final pixels = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            if (pixels == null) throw StateError('Cannot decode GPU atlas');
            atlases.add({
              'width': image.width,
              'height': image.height,
              'rgba': pixels.buffer.asUint8List(
                pixels.offsetInBytes,
                pixels.lengthInBytes,
              ),
            });
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
    }
    final atlasDecodeMilliseconds =
        watch.elapsedMicroseconds / 1000 - assetMilliseconds;
    final info = await _channel.invokeMapMethod<dynamic, dynamic>('create', {
      'moc': moc,
      'nativeApi': nativeApiAddress,
      'physics': physics,
      if (decodeAtlases) 'atlases': atlases else 'textures': textures,
      'maxTextureSize': maxTextureSize == 0 ? 4096 : maxTextureSize,
    });
    if (info == null) throw StateError('Native GPU returned no texture');
    final model = GpuLive2DModel._(info, Map.fromEntries(expressionEntries));
    model.loadMetrics.addAll({
      'assets_ms': assetMilliseconds,
      if (decodeAtlases) 'atlas_decode_ms': atlasDecodeMilliseconds,
      'load_ms': watch.elapsedMicroseconds / 1000,
      ...Map<String, num>.from(info['loadMetrics'] as Map? ?? const {}),
    });
    _models[model.textureId] = model;
    return model;
  }

  final int textureId, meshCount, maxSize, atlasBytes;
  final String backend;

  /// Startup wall timings (not GPU timer queries), for device diagnostics/QA.
  final Map<String, num> loadMetrics = {};
  final Map<String, List<Map<String, dynamic>>> _expressions;
  @override
  final ui.Rect bounds;
  @override
  List<LiveMesh> get meshes => const [];
  @override
  List<ui.Image> get textures => const [];
  @override
  List<String> get expressions => _expressions.keys.toList();
  @override
  double updateMilliseconds = 0;
  double submitMilliseconds = 0, presentMilliseconds = 0, frameMilliseconds = 0;
  int submittedFrames = 0;

  /// Optional benchmark observer; normal rendering does not notify widgets.
  VoidCallback? onFramePresented;
  int width = 0, height = 0;
  int actualWidth = 0, actualHeight = 0;
  double effectivePixelRatio = 1;
  bool _disposed = false, _pending = false, _resizePending = false;
  Future<void>? _flight;
  String? failure;
  bool get framePending => _pending;
  Map<String, Object> _parameters = {};

  /// Exact density unless bounded by the selected pixel or GPU dimension limit.
  /// Unlike Canvas compositing, this is a budget for the entire output texture.
  static (int, int, double) outputSize(
    Size size,
    double dpr,
    String quality, {
    int maxSize = 4096,
  }) {
    if (size.isEmpty ||
        !size.width.isFinite ||
        !size.height.isFinite ||
        !dpr.isFinite ||
        dpr <= 0) {
      return (0, 0, 1);
    }
    final budget = switch (quality) {
      'economy' => 1000000,
      'full' => 8000000,
      _ => 4000000,
    };
    final ratio = math.min(
      dpr,
      math.min(
        math.sqrt(budget / (size.width * size.height)),
        maxSize / math.max(size.width, size.height),
      ),
    );
    return (
      math.max(1, (size.width * ratio).floor()),
      math.max(1, (size.height * ratio).floor()),
      ratio,
    );
  }

  void configureSurface(Size size, double dpr, String quality) {
    if (_disposed || failure != null) return;
    final (w, h, ratio) = outputSize(size, dpr, quality, maxSize: maxSize);
    effectivePixelRatio = ratio;
    if (w == width && h == height || w == 0 || h == 0) return;
    width = w;
    height = h;
    if (_pending) {
      _resizePending = true;
      return;
    }
    if (_parameters.isEmpty) {
      tick(0, 0);
    } else {
      _submit(0);
    }
  }

  @override
  void tick(
    double seconds,
    double delta, {
    double mouth = 0,
    double lookX = 0,
    double lookY = 0,
    String expression = 'neutral',
  }) {
    if (_disposed || failure != null || _pending) return;
    final ids = <String>[], values = <double>[], blends = <int>[];
    applyLive2DParameters(
      (id, value, blend) {
        ids.add(id);
        values.add(value);
        blends.add(blend);
      },
      seconds: seconds,
      mouth: mouth,
      lookX: lookX,
      lookY: lookY,
      expression: _expressions[expression] ?? const [],
      overrides: parameterOverrides,
      weights: parameterWeights,
      studioMotion: studioMotion,
    );
    _parameters = {
      'ids': ids,
      'values': Float64List.fromList(values),
      'blends': Int32List.fromList(blends),
    };
    if (width > 0 && height > 0) _submit(delta);
  }

  void _submit(double delta) {
    _pending = true;
    _flight = _render(delta);
  }

  Future<void> _render(double delta) async {
    final watch = Stopwatch()..start();
    try {
      final metrics = await _channel.invokeMapMethod<dynamic, dynamic>(
        'frame',
        {
          'id': textureId,
          'width': width,
          'height': height,
          'delta': delta.clamp(0, .05),
          ..._parameters,
        },
      );
      if (_disposed || metrics?['paused'] == true) return;
      if (metrics == null) throw StateError('Native GPU returned no frame');
      updateMilliseconds = (metrics['updateMicros'] as num).toDouble() / 1000;
      submitMilliseconds = (metrics['submitMicros'] as num).toDouble() / 1000;
      presentMilliseconds = (metrics['presentMicros'] as num).toDouble() / 1000;
      frameMilliseconds = watch.elapsedMicroseconds / 1000;
      actualWidth = metrics['width'] as int;
      actualHeight = metrics['height'] as int;
      submittedFrames++;
      onFramePresented?.call();
    } catch (e) {
      if (!_disposed) {
        failure = e.toString();
        notifyListeners();
      }
    } finally {
      _pending = false;
      if (!_disposed && failure == null && _resizePending) {
        _resizePending = false;
        _submit(0);
      }
    }
  }

  Future<void> get settled async {
    while (_pending) {
      await _flight;
    }
  }

  /// Explicit diagnostic readback. Production frames never copy GPU pixels.
  Future<Uint8List> snapshotForTesting() async {
    await settled;
    return (await _channel.invokeMethod<Uint8List>('snapshot', {
      'id': textureId,
    }))!;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _models.remove(textureId);
    onFramePresented = null;
    unawaited(
      _channel
          .invokeMethod<void>('dispose', {'id': textureId})
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}

class Live2DGpuView extends StatelessWidget {
  const Live2DGpuView({super.key, required this.model, required this.quality});
  final GpuLive2DModel model;
  final String quality;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        model.configureSurface(size, dpr, quality);
      });
      return Texture(
        textureId: model.textureId,
        filterQuality: FilterQuality.medium,
      );
    },
  );
}
