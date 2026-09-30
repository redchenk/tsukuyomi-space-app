import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/user_center_page.dart';

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
    return {'success': true, 'data': {}};
  }
}

void main() {
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
