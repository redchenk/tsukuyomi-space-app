import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:tsukuyomi_space_app/core/season_theme.dart';
import 'package:tsukuyomi_space_app/features/room/room_music.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_desktop_navigation.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

void main() {
  setUpAll(() async {
    if (const bool.fromEnvironment('CAPTURE_UI')) {
      await loadSiteCaptureFonts();
    }
  });
  Future<bool> mount(WidgetTester tester) async {
    final shadows = debugDisableShadows;
    if (const bool.fromEnvironment('CAPTURE_UI')) debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = shadows);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      room.dispose();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('season-capture'),
        child: TsukuyomiApp(controller: room, loadNative: false),
      ),
    );
    await tester.pumpAndSettle();
    return shadows;
  }

  testWidgets(
    'new seasonal menus and music panels fit every season at desktop/mobile size',
    (tester) async {
      final shadows = await mount(tester);
      final season = SiteSeasonScope.maybeOf(
        tester.element(find.byType(SiteDesktopNavigation)),
      )!;
      for (final mode in SiteSeason.values) {
        await season.select(mode.name);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('site-navigation-group-0')));
        await tester.pumpAndSettle();
        await capture(tester, 'navigation-${mode.name}');
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      debugDisableShadows = shadows;
      final music = SiteMusicScope.maybeOf(
        tester.element(find.byType(SiteDesktopNavigation)),
      )!;
      for (final width in [1280.0, 390.0]) {
        tester.view.physicalSize = Size(width, 844);
        await tester.pumpAndSettle();
        showRoomMusic(tester.element(find.byType(Scaffold).first), music);
        await tester.pumpAndSettle();
        await capture(tester, 'music-${width.toInt()}');
        await tester.tap(find.text('网易云'));
        await tester.pumpAndSettle();
        await capture(tester, 'music-cloud-${width.toInt()}');
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'desktop discover preview and Create grouping match updated website',
    (tester) async {
      final shadows = await mount(tester);
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();
      expect(find.text('百科'), findsWidgets);
      expect(find.text('辉夜快跑'), findsOneWidget);
      expect(find.text('主舞台'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('创作'));
      await tester.pumpAndSettle();
      expect(find.text('主舞台'), findsOneWidget);
      expect(find.text('辉夜快跑'), findsNothing);
      expect(tester.takeException(), isNull);
      debugDisableShadows = shadows;
    },
  );
  testWidgets(
    'arrow keys enter panel, Escape restores trigger, outside closes',
    (tester) async {
      final shadows = await mount(tester);
      final trigger = find.descendant(
        of: find.byType(SiteDesktopNavigation),
        matching: find.widgetWithText(TextButton, '发现'),
      );
      final button = tester.widget<TextButton>(trigger);
      button.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.text('辉夜快跑'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(button.focusNode!.hasFocus, true);
      expect(find.text('辉夜快跑'), findsNothing);
      await tester.tap(find.text('空间'));
      await tester.pumpAndSettle();
      expect(find.text('RSS 订阅'), findsOneWidget);
      await tester.tapAt(const Offset(50, 850));
      await tester.pumpAndSettle();
      expect(find.text('RSS 订阅'), findsNothing);
      debugDisableShadows = shadows;
    },
  );
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byKey(const Key('season-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = const String.fromEnvironment(
      'UI_CAPTURE_DIR',
      defaultValue: 'artifacts/theme-v069',
    );
    final file = File('$directory/seasonal/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
