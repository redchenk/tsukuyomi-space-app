import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_space_app/core/storage.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_page.dart';
import 'package:tsukuyomi_space_app/features/site/site_explore_menu.dart';
import 'package:tsukuyomi_space_app/main.dart';

import 'support/fakes.dart';

class DelayedVerification extends FakeSite {
  final verified = Completer<Account>();
  @override
  Future<Account> me(String site) => verified.future;
}

void main() {
  test(
    'fresh model settings use real chat, retaining opt-in demo explicitly',
    () {
      expect(const RoomSettings().demo, false);
      expect(RoomSettings.fromJson({}).demo, false);
      expect(RoomSettings.fromJson({'demo': true}).demo, true);
    },
  );
  test(
    'local chat is ready before verification; pending messages survive sync',
    () async {
      final site = DelayedVerification();
      final store = MemoryStorage()
        ..value = const RoomSettings(model: 'fixture');
      store.drafts['account.https://yachiyo.hk'] = jsonEncode({
        'id': 'alice',
        'username': 'alice',
      });
      store.secrets['session.https://yachiyo.hk'] = 'session';
      final c = RoomController(
        storage: store,
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      final loading = c.initialize();
      for (var i = 0; c.loading && i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(c.loading, false);
      expect(c.verifyingSession, true);
      expect(c.account?.isAdministrator, false);
      await c.send('启动时立即聊天');
      expect(c.turns.single.user, '启动时立即聊天');
      expect(site.savedIds, isEmpty);
      site.verified.complete(const Account('alice', 'alice', role: 'admin'));
      await loading;
      expect(c.sessionVerified, true);
      expect(c.turns.single.user, '启动时立即聊天');
      expect(site.savedIds, hasLength(1));
      c.dispose();
    },
  );

  test(
    'v6 upgrade disables implicit demo and preserves historical demo records',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      SharedPreferences.setMockInitialValues({
        'settings': jsonEncode({'demo': true, 'model': 'configured'}),
        'history.demo': '[]',
      });
      final prefs = await SharedPreferences.getInstance();
      final storage = DeviceRoomStorage(prefs);
      expect((await storage.settings()).demo, false);
      expect((await storage.settings()).model, 'configured');
      expect(prefs.getString('history.demo'), '[]');
      await prefs.setString('settings', jsonEncode({'demo': true}));
      expect(
        (await storage.settings()).demo,
        true,
        reason: 'A subsequent explicit demo choice remains enabled.',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  testWidgets(
    'inline configuration saves the real provider and immediately enables chat',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStorage()..value = const RoomSettings();
      final c = RoomController(
        storage: store,
        chat: FakeChat(),
        site: FakeSite(),
        voice: SilentVoice(),
      );
      await c.initialize();
      await tester.pumpWidget(TsukuyomiApp(controller: c, loadNative: false));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byKey(const Key('room-quick-setup')),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'http://localhost:11434/api/chat');
      await tester.enterText(fields.at(1), 'configured-model');
      await tester.ensureVisible(find.text('保存并开始聊天'));
      await tester.tap(find.text('保存并开始聊天'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room-quick-setup')), findsNothing);
      expect(c.settings.model, 'configured-model');
      expect(c.settings.demo, false);
      await c.send('配置后直接聊天');
      await tester.pumpAndSettle();
      expect(c.turns.single.user, '配置后直接聊天');
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets(
    '2000 historical turns build lazily and preserve old viewport during append',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
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
      c.turns = List.generate(
        2000,
        (i) => ChatTurn(
          id: 'long-$i',
          user: 'question-$i',
          assistant: 'answer-$i',
          createdAt: DateTime(2020).add(Duration(seconds: i)),
        ),
      );
      await tester.pumpWidget(TsukuyomiApp(controller: c, loadNative: false));
      await tester.pumpAndSettle();
      expect(find.text('question-1999'), findsOneWidget);
      expect(find.text('question-0'), findsNothing);
      expect(find.byType(SelectableText).evaluate().length, lessThan(30));
      final list = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      list.controller!.jumpTo(-1200);
      await tester.pumpAndSettle();
      final position = list.controller!.position.pixels;
      await c.send('new while reading');
      await tester.pumpAndSettle();
      expect(list.controller!.position.pixels, position);
      expect(find.text('查看新消息'), findsOneWidget);
      await tester.tap(find.text('查看新消息'));
      await tester.pumpAndSettle();
      expect(find.text('new while reading'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  for (final width in [360.0, 390.0, 768.0, 1280.0, 1920.0]) {
    testWidgets(
      'Room and grouped menu at $width: languages, themes, large font, keyboard',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final language in ['zh', 'ja', 'en']) {
          for (final theme in ['dark', 'light']) {
            tester.platformDispatcher.textScaleFactorTestValue =
                language == 'en' ? 2 : 1;
            final store = MemoryStorage()..value = const RoomSettings();
            store.drafts['site-language'] = language;
            store.drafts['app-theme'] = theme;
            final c = RoomController(
              storage: store,
              chat: FakeChat(),
              site: FakeSite(),
              voice: SilentVoice(),
            );
            await c.initialize();
            await tester.pumpWidget(
              TsukuyomiApp(controller: c, loadNative: false),
            );
            await tester.pumpAndSettle();
            expect(find.byType(RoomPage), findsOneWidget);
            expect(find.byKey(const Key('room-quick-setup')), findsOneWidget);
            expect(
              tester.takeException(),
              isNull,
              reason: '$width $language $theme room',
            );
            await tester.tap(find.byIcon(Icons.menu_rounded));
            await tester.pumpAndSettle();
            expect(find.byType(SiteExploreMenu), findsOneWidget);
            expect(
              find.byIcon(Icons.admin_panel_settings_outlined),
              findsNothing,
            );
            expect(
              tester.takeException(),
              isNull,
              reason: '$width $language $theme menu',
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            final menuButton = tester.widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.menu_rounded),
            );
            expect(menuButton.focusNode!.hasFocus, true);
            await tester.pumpWidget(const SizedBox.shrink());
            c.dispose();
          }
        }
      },
    );
  }
}
