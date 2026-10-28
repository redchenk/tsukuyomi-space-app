import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'bindings.dart';
import 'animation_parameters.dart';
import 'gpu_model.dart';
import 'model.dart';
import 'shading.dart';

Future<Live2DModel> loadLive2D({
  String manifest = 'assets/live2d/character.model3.json',
  int maxTextureSize = 2048,
  String renderer = 'canvas',
}) async {
  if (maxTextureSize < 0) {
    throw ArgumentError.value(maxTextureSize, 'maxTextureSize');
  }
  if (nativeAvailable() != 1) {
    throw StateError('未安装 Cubism Native SDK。请先运行 tool/setup_live2d.py，再重新构建。');
  }
  // Keep the native asset reachable even for an exclusively GPU entrypoint,
  // and initialize its loader before Android resolves the JNI exports.
  String? fallback;
  if (renderer != 'canvas') {
    try {
      final api = Platform.isAndroid ? 0 : nativeGpuApi().address;
      if (!Platform.isAndroid && api == 0) {
        throw UnsupportedError('此平台尚未接入原生 GPU 纹理，使用兼容渲染。');
      }
      return await GpuLive2DModel.load(
        manifest: manifest,
        maxTextureSize: maxTextureSize,
        nativeApiAddress: api,
        decodeAtlases: Platform.isLinux || Platform.isWindows,
      );
    } catch (e) {
      if (renderer == 'gpu') rethrow;
      fallback = e.toString();
    }
  }
  final json =
      jsonDecode(await rootBundle.loadString(manifest)) as Map<String, dynamic>;
  final refs = json['FileReferences'] as Map<String, dynamic>;
  final base = Uri.parse(manifest).resolve('.');
  String asset(String path) {
    final uri = base.resolve(path);
    if (uri.hasScheme ||
        !uri.path.startsWith(base.path) ||
        path.startsWith('/')) {
      throw FormatException('模型资源路径无效');
    }
    return uri.toString();
  }

  final moc = await rootBundle.load(asset(refs['Moc'] as String));
  final physics = refs['Physics'] is String
      ? await rootBundle.load(asset(refs['Physics'] as String))
      : null;
  final textures = <ui.Image>[];
  final tintProgram = await loadLive2DTintProgram();
  final expressions = <String, List<Map<String, dynamic>>>{};
  Pointer<Void> ptr = nullptr;
  try {
    for (final path in refs['Textures'] as List) {
      final data = await rootBundle.load(asset(path as String));
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
        getTargetSize: (width, height) {
          if (maxTextureSize == 0 ||
              math.max(width, height) <= maxTextureSize) {
            return const ui.TargetImageSize();
          }
          final scale = maxTextureSize / math.max(width, height);
          return ui.TargetImageSize(
            width: math.max(1, (width * scale).round()),
            height: math.max(1, (height * scale).round()),
          );
        },
      );
      try {
        textures.add((await codec.getNextFrame()).image);
      } finally {
        codec.dispose();
      }
    }
    for (final entry in (refs['Expressions'] as List? ?? [])) {
      final value = jsonDecode(
        await rootBundle.loadString(asset(entry['File'] as String)),
      ) as Map;
      expressions[entry['Name'] as String] = (value['Parameters'] as List)
          .cast<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    }
    ptr = using((arena) {
      final bytes = arena<Uint8>(moc.lengthInBytes);
      bytes
          .asTypedList(moc.lengthInBytes)
          .setAll(
            0,
            moc.buffer.asUint8List(moc.offsetInBytes, moc.lengthInBytes),
          );
      final p = physics == null
          ? nullptr.cast<Uint8>()
          : arena<Uint8>(physics.lengthInBytes);
      if (physics != null) {
        p
            .asTypedList(physics.lengthInBytes)
            .setAll(
              0,
              physics.buffer.asUint8List(
                physics.offsetInBytes,
                physics.lengthInBytes,
              ),
            );
      }
      return nativeCreate(
        bytes,
        moc.lengthInBytes,
        p,
        physics?.lengthInBytes ?? 0,
      );
    });
    if (ptr == nullptr) throw StateError('模型无效，或使用了尚未支持的 Cubism 5.3 离屏混合。');
    final result = _NativeModel(ptr, textures, expressions, tintProgram)
      ..rendererFallbackReason = fallback;
    result.tick(0, 1 / 60);
    result._calculateBounds();
    return result;
  } catch (_) {
    if (ptr != nullptr) nativeDestroy(ptr);
    for (final texture in textures) {
      texture.dispose();
    }
    rethrow;
  }
}

class _NativeModel extends Live2DModel {
  _NativeModel(this._ptr, this.textures, this._expressions, this.tintProgram)
    : _count = nativeMeshCount(_ptr) {
    _nativeMeshes = calloc<NativeMesh>(_count);
  }
  Pointer<Void> _ptr;
  final int _count;
  late final Pointer<NativeMesh> _nativeMeshes;
  final _ids = <String, Pointer<Char>>{};
  final Map<String, List<Map<String, dynamic>>> _expressions;
  @override
  final ui.FragmentProgram tintProgram;
  @override
  final List<ui.Image> textures;
  @override
  List<LiveMesh> meshes = [];
  @override
  ui.Rect bounds = const ui.Rect.fromLTRB(-1, -1, 1, 1);
  @override
  double updateMilliseconds = 0;
  @override
  List<String> get expressions => _expressions.keys.toList();

  void parameter(String id, double value, [int blend = 0]) {
    final key = _ids.putIfAbsent(id, () => id.toNativeUtf8().cast<Char>());
    nativeParameter(_ptr, key, value, blend);
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
    if (_ptr == nullptr) return;
    final timer = Stopwatch()..start();
    nativeBegin(_ptr);
    applyLive2DParameters(
      parameter,
      seconds: seconds,
      mouth: mouth,
      lookX: lookX,
      lookY: lookY,
      expression: _expressions[expression] ?? const [],
      overrides: parameterOverrides,
      weights: parameterWeights,
      studioMotion: studioMotion,
    );
    nativeUpdate(_ptr, delta);
    if (nativeMeshes(_ptr, _nativeMeshes, _count) != 1) {
      throw StateError('模型网格数据无效');
    }
    if (meshes.isEmpty) {
      meshes = List.generate(_count, (index) {
        final m = (_nativeMeshes + index).ref;
        return LiveMesh(
          positions: m.positions.asTypedList(m.vertices * 2),
          uvs: m.uvs.asTypedList(m.vertices * 2),
          indices: m.triangles.asTypedList(m.indices),
          texture: m.texture,
          order: m.order,
          flags: m.flags,
          visible: m.visible != 0,
          opacity: m.opacity,
          masks: m.maskCount == 0
              ? []
              : m.masks.asTypedList(m.maskCount).toList(),
          multiply: List.generate(4, (i) => m.multiply[i]),
          screen: List.generate(4, (i) => m.screen[i]),
          geometryRevision: 0,
          staticTopology: true,
        );
      });
    } else {
      for (var index = 0; index < _count; index++) {
        final m = (_nativeMeshes + index).ref, mesh = meshes[index];
        mesh.order = m.order;
        mesh.visible = m.visible != 0;
        mesh.opacity = m.opacity;
        if (m.positionsChanged != 0) {
          mesh.geometryRevision = mesh.geometryRevision! + 1;
        }
        for (var channel = 0; channel < 4; channel++) {
          mesh.multiply[channel] = m.multiply[channel];
          mesh.screen[channel] = m.screen[channel];
        }
      }
    }
    updateMilliseconds = timer.elapsedMicroseconds / 1000;
    notifyListeners();
  }

  void _calculateBounds() {
    var left = double.infinity,
        top = double.infinity,
        right = -double.infinity,
        bottom = -double.infinity;
    for (final m in meshes.where((m) => m.visible && m.opacity > .01)) {
      for (var i = 0; i < m.positions.length; i += 2) {
        left = math.min(left, m.positions[i]);
        right = math.max(right, m.positions[i]);
        top = math.min(top, -m.positions[i + 1]);
        bottom = math.max(bottom, -m.positions[i + 1]);
      }
    }
    if (left.isFinite && right > left && bottom > top) {
      bounds = ui.Rect.fromLTRB(left, top, right, bottom);
    }
  }

  @override
  void dispose() {
    if (_ptr == nullptr) return;
    nativeDestroy(_ptr);
    _ptr = nullptr;
    calloc.free(_nativeMeshes);
    for (final id in _ids.values) {
      calloc.free(id);
    }
    for (final image in textures) {
      image.dispose();
    }
    meshes = [];
    super.dispose();
  }
}
