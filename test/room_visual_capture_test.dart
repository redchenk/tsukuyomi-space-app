import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';

import 'support/fakes.dart';

import 'package:tsukuyomi_space_app/core/models.dart';

// Opt-in local visual QA: real Cubism and system fonts, never Ahem screenshots.
// CI does not have the locally licensed model/SDK or macOS fonts.
void main() {
  testWidgets('capture desktop and mobile Room with native model', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = Directory(
        '/System/Library/AssetsV2/com_apple_MobileAsset_Font8',
      );
      final ping = root
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('/PingFang.ttc'));
      for (final family in ['Roboto', 'PingFang SC']) {
        await (FontLoader(family)..addFont(
              Future.value(ByteData.sublistView(await ping.readAsBytes())),
            ))
            .load();
      }
      final song = await File(
        const String.fromEnvironment(
          'QA_SERIF_FONT',
          defaultValue: '/System/Library/Fonts/Supplemental/Songti.ttc',
        ),
      ).readAsBytes();
      await (FontLoader(
        'Songti SC',
      )..addFont(Future.value(ByteData.sublistView(song)))).load();
      await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
            rootBundle.load(
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            ),
          ))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final size in [const Size(1417, 960), const Size(390, 844)]) {
      final c = RoomController(
        storage: MemoryStorage()
          ..value = const RoomSettings(
            demo: false,
            llmUrl: 'https://api.openai.com/v1/chat/completions',
          ),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      final model = await tester.runAsync(() => loadLive2D());
      expect(model, isNotNull);
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture'),
          child: TsukuyomiApp(controller: c, modelLoader: () async => model!),
        ),
      );
      // Asset decoding/native initialization run outside the test's fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
        find.byKey(const Key('capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final path =
            'artifacts/room-parity/native-room-${size.width > 860 ? 'desktop' : 'mobile'}.png';
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UI'));
}
