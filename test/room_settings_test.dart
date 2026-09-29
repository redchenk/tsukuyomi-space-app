import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 390.0, 861.0, 1280.0]) {
    for (final section in roomSections.keys) {
      testWidgets(
        'Room settings $section at $width has usable controls without overflow',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final c = RoomController(
            storage: MemoryStorage(),
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await c.initialize();
          addTearDown(c.dispose);
          await tester.pumpWidget(
            MaterialApp(
              home: RoomSettingsPage(controller: c, initialSection: section),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(SingleChildScrollView).first,
            const Offset(0, -600),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('model edits save without exposing secrets in preferences', (
    tester,
  ) async {
    final storage = MemoryStorage();
    final c = RoomController(
      storage: storage,
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RoomSettingsPage(controller: c, initialSection: 'model'),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byType(Slider).first;
    await tester.ensureVisible(slider);
    await tester.tap(slider);
    await tester.pump();
    expect(find.text('保存全部'), findsOneWidget);
    await tester.tap(find.text('保存并进入房间'));
    await tester.pumpAndSettle();
    expect(storage.value.options['modelScale'], isA<num>());
    expect(storage.value.toJson().keys, isNot(contains('apiKey')));
  });
  testWidgets('capture settings desktop and mobile using native fonts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final ping =
          Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
              .listSync(recursive: true)
              .whereType<File>()
              .firstWhere((f) => f.path.endsWith('/PingFang.ttc'));
      for (final family in ['Roboto', 'PingFang SC']) {
        await (FontLoader(family)..addFont(
              Future.value(ByteData.sublistView(await ping.readAsBytes())),
            ))
            .load();
      }
      await (FontLoader('Songti SC')..addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  const String.fromEnvironment(
                    'QA_SERIF_FONT',
                    defaultValue:
                        '/System/Library/Fonts/Supplemental/Songti.ttc',
                  ),
                ).readAsBytes(),
              ),
            ),
          ))
          .load();
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
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(1280, 900), const Size(390, 844)]) {
      tester.view.physicalSize = size;
      final c = RoomController(
        storage: MemoryStorage()
          ..value = const RoomSettings(
            demo: false,
            llmUrl: 'https://api.openai.com/v1/chat/completions',
            model: '',
          ),
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'PingFang SC',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff60439f),
                surface: Colors.white,
              ),
              inputDecorationTheme: InputDecorationTheme(
                filled: true,
                fillColor: const Color(0xffefedf7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            home: RoomSettingsPage(controller: c),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
        find.byKey(const Key('capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'artifacts/room-parity/native-settings-${size.width > 860 ? 'desktop' : 'mobile'}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    }
  }, skip: !const bool.fromEnvironment('CAPTURE_UI'));
}
