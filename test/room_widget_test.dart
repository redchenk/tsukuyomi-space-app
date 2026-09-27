import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

void main() {
  Future<RoomController> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
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
      RepaintBoundary(
        key: const Key('screenshot'),
        child: TsukuyomiApp(controller: c, loadNative: false),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  for (final size in [
    const Size(1440, 960),
    const Size(390, 844),
    const Size(320, 640),
  ]) {
    testWidgets('Room fits ${size.width} × ${size.height} and sends a turn', (
      tester,
    ) async {
      final c = await mount(tester, size);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const Key('message-input')), '晚上好');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(c.turns.single.user, '晚上好');
      expect(find.text('这是完整回复。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_UI')) {
        final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
          find.byKey(const Key('screenshot')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('artifacts/room-${size.width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }
  testWidgets('Command Enter sends a message from the composer', (
    tester,
  ) async {
    final c = await mount(tester, const Size(1440, 960));
    await tester.enterText(find.byKey(const Key('message-input')), 'keyboard');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(c.turns.single.user, 'keyboard');
  });
  testWidgets('stop remains available while input is read only', (
    tester,
  ) async {
    final c = await mount(tester, const Size(390, 844));
    (c.chat as FakeChat).controlled = true;
    await tester.enterText(find.byKey(const Key('message-input')), 'hello');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    expect(c.generating, true);
    await tester.tap(find.byTooltip('停止生成'));
    await tester.pump();
    expect(c.generating, false);
    expect(c.turns, isEmpty);
  });
  testWidgets('mobile keyboard keeps composer visible', (tester) async {
    await mount(tester, const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 330);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getBottomRight(find.byKey(const Key('message-input'))).dy,
      lessThanOrEqualTo(514),
    );
  });
}
