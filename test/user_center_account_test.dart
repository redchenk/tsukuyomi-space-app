import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/user_center_page.dart';
import 'package:tsukuyomi_space_app/features/site/native_gallery_details.dart';

import 'support/fakes.dart';

Map<String, dynamic> accountProfile(String owner) => {
  'success': true,
  'data': {
    'id': owner,
    'username': owner,
    'email': '$owner@example.com',
    'bio': '$owner 的私有介绍',
    'created_at': '2026-09-30',
  },
};

class AccountProfileSite extends FakeSite implements SiteDataService {
  final profiles = <String>[];
  Completer<Map<String, dynamic>>? pendingAlice;
  Map<String, dynamic> growth = {};
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/user/profile') {
      final owner = userId;
      profiles.add(owner);
      if (owner == 'alice' && pendingAlice != null) return pendingAlice!.future;
      return accountProfile(owner);
    }
    if (path == '/api/growth/me') return {'success': true, 'data': growth};
    return {'success': true, 'data': {}};
  }
}

void main() {
  for (final level in [
    {
      'level': {
        'level': 8,
        'title': '永恒月契',
        'totalXp': 7654,
        'progressPercent': 42,
      },
    },
    {
      'summary': {'level': 8},
    },
  ]) {
    testWidgets(
      'Account growth parses ${level.keys.first} and routes through the badge without printing objects',
      (tester) async {
        final site = AccountProfileSite()..growth = level;
        final room = RoomController(
          storage: MemoryStorage(),
          site: site,
          chat: FakeChat(),
          voice: SilentVoice(),
        );
        addTearDown(room.dispose);
        await room.initialize();
        await room.login('alice', 'test-password');
        final destinations = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: UserCenterPage(controller: room, onGo: destinations.add),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Lv.8'), findsOneWidget);
        expect(find.text('永恒月契'), findsOneWidget);
        expect(
          tester
              .widget<NativeUserLevelBadge>(find.byType(NativeUserLevelBadge))
              .level,
          8,
        );
        expect(
          tester
              .widgetList<Text>(find.byType(Text))
              .any((text) => '${text.data}'.contains('totalXp')),
          isFalse,
        );
        await tester.ensureVisible(
          find.byKey(const Key('account-growth-link')),
        );
        await tester.tap(find.byKey(const Key('account-growth-link')));
        expect(destinations, ['/growth']);
        expect(find.text('新建投稿'), findsOneWidget);
        expect(find.text('图库管理'), findsOneWidget);
        expect(find.text('附件库'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'default demo mode isolates account center and ignores a late previous profile',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = AccountProfileSite();
      final room = RoomController(
        storage: MemoryStorage(),
        site: site,
        chat: FakeChat(),
        voice: SilentVoice(),
      );
      addTearDown(room.dispose);
      await room.initialize();
      await room.login('alice', 'test-password');
      expect(room.settings.demo, isTrue);
      expect(room.scope, 'demo');
      await tester.pumpWidget(
        MaterialApp(
          home: UserCenterPage(controller: room, onGo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('alice 的私有介绍'), findsWidgets);
      final delayed = Completer<Map<String, dynamic>>();
      site.pendingAlice = delayed;
      final pendingRefresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(site.profiles, ['alice', 'alice']);
      await room.login('bob', 'test-password');
      await tester.pumpAndSettle();
      expect(
        room.scope,
        'demo',
        reason:
            'Room demonstration scope remains independent of the site account',
      );
      expect(find.text('alice 的私有介绍'), findsNothing);
      expect(find.text('bob 的私有介绍'), findsWidgets);
      expect(site.profiles, ['alice', 'alice', 'bob']);
      delayed.complete(accountProfile('alice'));
      await pendingRefresh;
      await tester.pumpAndSettle();
      expect(find.text('alice 的私有介绍'), findsNothing);
      expect(find.text('bob 的私有介绍'), findsWidgets);
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .where((field) => field.controller?.text == 'bob 的私有介绍'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
