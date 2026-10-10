import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import 'package:tsukuyomi_space_app/core/app_update_installer.dart';

// Run this release entrypoint on devices, not only with the host test runner.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Platform.isAndroid) {
      const updates = MethodChannel('space.tsukuyomi/app_update');
      final abis = await updates.invokeListMethod<String>('supportedAbis');
      if (abis == null || abis.isEmpty) {
        throw StateError('Missing native update ABI');
      }
      final installed = await InstalledApp.load();
      final cache = await getApplicationCacheDirectory();
      final outside = await File('${cache.path}/outside-update.apk')
          .writeAsString('not an APK');
      final root = await Directory('${cache.path}/tsukuyomi-updates').create();
      final invalid = await File('${root.path}/invalid.apk')
          .writeAsString('not an APK');
      try {
        for (final (path, expected) in [
          (outside.path, 'storage'),
          (invalid.path, 'package'),
        ]) {
          try {
            await updates.invokeMethod('install', {'path': path});
            throw StateError('Unsafe update was not blocked');
          } on PlatformException catch (e) {
            if (e.code != expected) rethrow;
          }
        }
      } finally {
        await outside.delete();
        await invalid.delete();
      }
      // ignore: avoid_print
      print(
        'TSUKUYOMI_UPDATE_OK abis=$abis platform=${installed.platform.name} version=${installed.version.value} private-cache=$cache',
      );
    }
    final model = await loadLive2D();
    if (model.meshes.length < 10 || model.textures.isEmpty) {
      throw StateError('Cubism returned an empty model');
    }
    runApp(
      MaterialApp(
        home: Scaffold(
          body: CustomPaint(
            painter: Live2DPainter(model),
            size: const Size(390, 800),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    for (var i = 0; i < 120; i++) {
      model.tick(i / 60, 1 / 60, mouth: (i % 30) / 30);
      await Future<void>.delayed(const Duration(milliseconds: 17));
    }
    // ignore: avoid_print
    print(
      'TSUKUYOMI_LIVE2D_OK meshes=${model.meshes.length} textures=${model.textures.length}',
    );
  } catch (e, st) {
    // ignore: avoid_print
    print('TSUKUYOMI_LIVE2D_FAILED $e\n$st');
    exit(1);
  }
}
