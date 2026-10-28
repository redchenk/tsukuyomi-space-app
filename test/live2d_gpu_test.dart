import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_live2d/animation_parameters.dart';
import 'package:tsukuyomi_space_app/live2d/live2d_scene_controller.dart';

class _GpuClock implements TickerProvider {
  late TickerCallback frame;
  @override
  Ticker createTicker(TickerCallback onTick) {
    frame = onTick;
    return Ticker(onTick);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('space.tsukuyomi/live2d_gpu');
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall)? frame;
  setUp(() {
    calls.clear();
    frame = null;
    binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
      data,
    ) async {
      final path = utf8.decode(
        data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final bytes = utf8.encode(
        path.endsWith('model3.json')
            ? jsonEncode({
                'FileReferences': {
                  'Moc': 'model.moc3',
                  'Textures': ['texture.png'],
                  'Expressions': [
                    {'Name': 'happy', 'File': 'happy.exp3.json'},
                  ],
                },
              })
            : path.endsWith('exp3.json')
            ? jsonEncode({
                'Parameters': [
                  {'Id': 'ParamEyeLOpen', 'Value': .6, 'Blend': 'Multiply'},
                ],
              })
            : 'fixture',
      );
      return ByteData.sublistView(Uint8List.fromList(bytes));
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'create') {
        return {
          'textureId': 7,
          'meshCount': 409,
          'bounds': [-1.0, -2.0, 1.0, 2.0],
          'maxSize': 4096,
          'atlasBytes': 100663280,
          'backend': 'Metal',
        };
      }
      if (call.method == 'frame') {
        if (frame != null) return frame!(call);
        return {
          'updateMicros': 1000.0,
          'submitMicros': 500.0,
          'presentMicros': 200.0,
          'width': call.arguments['width'],
          'height': call.arguments['height'],
        };
      }
      return null;
    });
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      null,
    );
  });
  Future<GpuLive2DModel> load() => GpuLive2DModel.load(
    manifest: 'gpu-fixture/model3.json',
    maxTextureSize: 3072,
  );

  test(
    'Studio weights cross the native GPU channel and silence wins last',
    () async {
      final model = await load();
      addTearDown(model.dispose);
      model.configureSurface(const Size(390, 800), 2, 'auto');
      await model.settled;
      calls.clear();
      model
        ..studioMotion = true
        ..parameterOverrides = {'ParamAngleX': 12, 'ParamMouthOpenY': .7}
        ..parameterWeights = {'ParamAngleX': .35, 'ParamMouthOpenY': .8}
        ..tick(1, 1 / 60, mouth: 0, expression: 'happy');
      await model.settled;
      final args =
          calls.singleWhere((c) => c.method == 'frame').arguments as Map;
      expect(args['ids'], [
        'ParamAngleX',
        'ParamMouthOpenY',
        'ParamMouthOpenY',
      ]);
      expect(args['values'], [12, .7, 0]);
      expect(args['blends'], [
        weightedParameterBlend(.35),
        weightedParameterBlend(.8),
        0,
      ]);
    },
  );

  test(
    'desktop atlas decode preserves premultiplied alpha and bounds size',
    () async {
      final atlas = image.Image(width: 4, height: 2, numChannels: 4);
      image.fill(atlas, color: image.ColorRgba8(128, 64, 32, 128));
      final png = image.encodePng(atlas);
      binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets', (
        data,
      ) async {
        final path = utf8.decode(
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        return ByteData.sublistView(
          path.endsWith('.png')
              ? png
              : Uint8List.fromList(
                  utf8.encode(
                    path.endsWith('.json')
                        ? '{"FileReferences":{"Moc":"m.moc3","Textures":["t.png"]}}'
                        : 'fixture',
                  ),
                ),
        );
      });
      final model = await GpuLive2DModel.load(
        manifest: 'desktop-decode/model3.json',
        maxTextureSize: 2,
        decodeAtlases: true,
      );
      final args = calls.single.arguments as Map;
      expect(args.containsKey('textures'), false);
      final result = (args['atlases'] as List).single as Map;
      expect([result['width'], result['height']], [2, 1]);
      expect(result['rgba'], [64, 32, 16, 128, 64, 32, 16, 128]);
      model.dispose();
    },
  );

  test(
    'platform backend and native asset ABI survive channel handoff',
    () async {
      final model = await GpuLive2DModel.load(
        manifest: 'gpu-fixture/model3.json',
        maxTextureSize: 3072,
        nativeApiAddress: 123456,
      );
      expect(model.backend, 'Metal');
      expect(calls.single.arguments['nativeApi'], 123456);
      model.dispose();
    },
  );

  test(
    'independent assets start together and create waits for all of them',
    () async {
      final gate = Completer<void>(), requested = <String>[];
      final original = binding.defaultBinaryMessenger;
      original.setMockMessageHandler('flutter/assets', (data) async {
        final path = utf8.decode(
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        requested.add(path);
        if (path.endsWith('model3.json')) {
          return ByteData.sublistView(
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'FileReferences': {
                    'Moc': 'm.moc3',
                    'Physics': 'p.json',
                    'Textures': ['a.png', 'b.png'],
                    'Expressions': [
                      {'Name': 'neutral', 'File': 'e.json'},
                    ],
                  },
                }),
              ),
            ),
          );
        }
        await gate.future;
        return ByteData.sublistView(
          Uint8List.fromList(
            utf8.encode(
              path.endsWith('e.json') ? '{"Parameters":[]}' : 'fixture',
            ),
          ),
        );
      });
      final pending = GpuLive2DModel.load(
        manifest: 'parallel/model3.json',
        maxTextureSize: 3072,
      );
      await Future<void>.delayed(Duration.zero);
      final allStarted = requested.length;
      final createdEarly = calls.any((c) => c.method == 'create');
      gate.complete();
      final model = await pending;
      model.dispose();
      expect(allStarted, 6);
      expect(createdEarly, false);
      expect(calls.where((c) => c.method == 'create'), hasLength(1));
      expect(
        model.loadMetrics['load_ms'],
        greaterThanOrEqualTo(model.loadMetrics['assets_ms']!),
      );
    },
  );

  test('GPU keeps animating during interaction with one frame in flight; hidden still pauses', () async {
    final model = await load(), clock = _GpuClock();
    model.configureSurface(const Size(390, 800), 3, 'auto');
    await model.settled;
    final scene = Live2DSceneController(
      vsync: clock,
      mobile: true,
      onTick: (seconds, delta) => model.tick(seconds, delta),
    );
    addTearDown(scene.dispose);
    scene.attach(model);
    scene.active = true;
    scene.interacting = true;
    expect(scene.fps, 60);
    clock.frame(Duration.zero);
    final gate = Completer<Object?>();
    frame = (_) => gate.future;
    clock.frame(const Duration(milliseconds: 17));
    await Future<void>.delayed(Duration.zero);
    expect(model.framePending, true);
    clock.frame(const Duration(milliseconds: 34));
    expect(scene.modelFrames, 1);
    expect(scene.backpressureYields, 1);
    gate.complete({
      'updateMicros': 1,
      'submitMicros': 1,
      'presentMicros': 1,
      'width': 1170,
      'height': 2400,
    });
    await model.settled;
    frame = null;
    for (var i = 3; i <= 10; i++) {
      scene.interacting = false;
      scene.interacting = true;
      clock.frame(Duration(milliseconds: i * 17));
      await model.settled;
    }
    expect(scene.modelFrames, 9);
    expect(model.failure, isNull);
    scene.active = false;
    clock.frame(const Duration(seconds: 1));
    expect(scene.modelFrames, 9);
  });

  test(
    'native output retains phone DPR and caps total pixels / dimensions',
    () {
      expect(GpuLive2DModel.outputSize(const Size(390, 800), 3, 'auto'), (
        1170,
        2400,
        3.0,
      ));
      for (final quality in ['auto', 'economy', 'full']) {
        final (w, h, _) = GpuLive2DModel.outputSize(
          const Size(2000, 4000),
          4,
          quality,
        );
        expect(
          w * h,
          lessThanOrEqualTo(switch (quality) {
            'auto' => 4000000,
            'full' => 8000000,
            _ => 1000000,
          }),
        );
        expect(h, lessThanOrEqualTo(4096));
      }
      expect(GpuLive2DModel.outputSize(Size.zero, 3, 'auto'), (0, 0, 1));
    },
  );

  test('one parameter batch preserves expression / override / mouth order, without meshes', () async {
    final model = await load();
    model.configureSurface(const Size(390, 800), 3, 'auto');
    await model.settled;
    model.parameterOverrides = {'ParamEyeLOpen': .25, 'ParamMouthOpenY': 0};
    model.tick(3, .016, mouth: .9, expression: 'happy');
    await model.settled;
    final args = calls.last.arguments as Map;
    expect(args['ids'].last, 'ParamMouthOpenY');
    expect(args['values'].last, .9);
    final indices = [
      for (var i = 0; i < args['ids'].length; i++)
        if (args['ids'][i] == 'ParamEyeLOpen') i,
    ];
    expect(indices.length, 3);
    expect(args['blends'][indices[1]], 2);
    expect(args['values'][indices.last], .25);
    expect(model.meshes, isEmpty);
    expect(model.textures, isEmpty);
    expect(model.submittedFrames, 2);
    expect(model.actualWidth, 1170);
    model.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls.last.method, 'dispose');
  });

  test(
    'backpressure drops overlapping ticks and coalesces frozen resizes',
    () async {
      final model = await load();
      final gate = Completer<Object?>();
      frame = (_) => gate.future;
      model.configureSurface(const Size(300, 600), 2, 'auto');
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 100; i++) {
        model.tick(i.toDouble(), .016);
      }
      model.configureSurface(const Size(400, 700), 2, 'auto');
      model.configureSurface(const Size(500, 800), 2, 'auto');
      expect(calls.where((c) => c.method == 'frame').length, 1);
      frame = null;
      gate.complete({
        'updateMicros': 1000,
        'submitMicros': 500,
        'presentMicros': 200,
        'width': 600,
        'height': 1200,
      });
      await model.settled;
      final frames = calls.where((c) => c.method == 'frame').toList();
      expect(frames.length, 2);
      expect(frames.last.arguments['width'], 1000);
      expect(frames.last.arguments['height'], 1600);
      expect(frames.last.arguments['delta'], 0);
      model.dispose();
    },
  );

  test('native failure stops submission and notifies fallback once', () async {
    final model = await load();
    var errors = 0;
    model.addListener(() => errors++);
    frame = (_) async =>
        throw PlatformException(code: 'gpu', message: 'context lost');
    model.configureSurface(const Size(390, 800), 3, 'auto');
    await model.settled;
    expect(model.failure, contains('context lost'));
    expect(errors, 1);
    model.tick(1, .016);
    expect(calls.where((c) => c.method == 'frame').length, 1);
    model.dispose();
  });

  test(
    'late native completion after disposal does not notify or resubmit',
    () async {
      final model = await load();
      final gate = Completer<Object?>();
      frame = (_) => gate.future;
      model.configureSurface(const Size(390, 800), 3, 'auto');
      await Future<void>.delayed(Duration.zero);
      model.configureSurface(const Size(800, 390), 3, 'auto');
      model.dispose();
      gate.completeError(PlatformException(code: 'gpu'));
      await model.settled;
      expect(calls.where((c) => c.method == 'frame').length, 1);
      expect(model.failure, isNull);
    },
  );
  test(
    'a replacement Surface refreshes a paused pose without advancing time',
    () async {
      final model = await load();
      model.configureSurface(const Size(390, 800), 3, 'auto');
      await model.settled;
      final reply = Completer<void>();
      binding.channelBuffers.push(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('surfaceAvailable', {'id': 7}),
        ),
        (_) => reply.complete(),
      );
      await reply.future;
      await model.settled;
      final frames = calls.where((c) => c.method == 'frame').toList();
      expect(frames.length, 2);
      expect(frames.last.arguments['delta'], 0);
      expect(frames.last.arguments['values'], frames.first.arguments['values']);
      model.dispose();
    },
  );
}
