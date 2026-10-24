import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_mobile_navigation.dart';
import 'package:tsukuyomi_space_app/features/site/site_explore_menu.dart';
import 'package:tsukuyomi_space_app/features/site/site_guide.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';
import 'site_navigation_test.dart' show NavigationSite;

Future<RoomController> mount(WidgetTester tester, {double width = 390}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final room = RoomController(
    storage: MemoryStorage(),
    site: NavigationSite(),
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  await room.login('traveler', 'fixture-password');
  addTearDown(room.dispose);
  await tester.pumpWidget(
    TsukuyomiApp(controller: room, initialPath: '/hub', loadNative: false),
  );
  await tester.pumpAndSettle();
  return room;
}

void main() {
  for (final width in [320.0, 390.0, 768.0]) {
    testWidgets(
      'mobile explore at $width opens below the bar and preserves route on back',
      (tester) async {
        await mount(tester, width: width);
        await tester.tap(find.byTooltip('探索'));
        await tester.pumpAndSettle();
        final panel = tester.getRect(find.byType(SiteMobileNavigation));
        expect(panel.left, 12);
        expect(panel.top, 78);
        expect(panel.right, width - 12);
        expect(panel.bottom, lessThanOrEqualTo(832));
        for (final path in ['/hub', '/room', '/plaza', '/stage']) {
          final target = find.byKey(ValueKey('mobile-nav-primary-$path'));
          expect(target.hitTestable(), findsOneWidget);
          expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
        }
        // The pet must not intercept the modal's bottom-right links.
        expect(find.byType(SiteGuideButton), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(SiteMobileNavigation), findsNothing);
        final trigger = tester.widget<IconButton>(
          find.descendant(
            of: find.byType(SiteExploreMenu),
            matching: find.byType(IconButton),
          ),
        );
        expect(trigger.focusNode!.hasFocus, isTrue);
        expect(find.byType(SiteGuideButton), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mobile discovery search opens once and can navigate without losing login',
    (tester) async {
      final room = await mount(tester);
      await tester.tap(find.byTooltip('探索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mobile-nav-search')));
      await tester.pumpAndSettle();
      expect(find.byType(SiteMobileNavigation), findsNothing);
      expect(find.text('想找些什么？'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '主舞台');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, '主舞台').first);
      await tester.pumpAndSettle();
      expect(find.byType(SitePage), findsOneWidget);
      expect(room.account?.id, 'traveler');
      expect(room.sessionVerified, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'open account menu removes private actions when the session expires',
    (tester) async {
      final room = await mount(tester);
      room.account = const Account('traveler', 'traveler', role: 'admin');
      room.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账号菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多 App 功能'));
      await tester.pumpAndSettle();
      expect(find.text('管理终端'), findsOneWidget);
      await room.logout();
      await tester.pumpAndSettle();
      expect(find.text('管理终端'), findsNothing);
      expect(find.text('退出'), findsNothing);
      expect(find.byKey(const ValueKey('mobile-nav-/login')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
