import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/login_dialog.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('password, email, registration and reset fit $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = RoomController(
        storage: MemoryStorage(),
        site: FakeSite(),
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      await c.initialize();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showSiteLogin(context, c),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('欢迎回来'), findsOneWidget);
      await tester.tap(find.text('验证码登录'));
      await tester.pumpAndSettle();
      expect(find.text('发送验证码'), findsOneWidget);
      await tester.ensureVisible(find.text('注册'));
      await tester.tap(find.text('注册'));
      await tester.pumpAndSettle();
      expect(find.text('加入月读空间'), findsOneWidget);
      await tester.ensureVisible(find.text('忘记密码'));
      await tester.tap(find.text('忘记密码'));
      await tester.pumpAndSettle();
      expect(find.text('重设密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
