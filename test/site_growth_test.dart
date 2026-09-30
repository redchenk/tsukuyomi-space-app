import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/site_page.dart';

import 'support/fakes.dart';

Map<String, dynamic> growthState({bool checked = false, int xp = 0}) => {
  'level': {'level': 1, 'title': '初次连接', 'totalXp': xp, 'progressPercent': 0},
  'streak': {'current': checked ? 1 : 0, 'longest': checked ? 1 : 0},
  'today': {
    'completed': checked ? 1 : 0,
    'total': 1,
    'tasks': [
      {
        'key': 'checkin',
        'label': '每日签到',
        'completed': checked,
        'path': '/growth',
        'xp': 5,
      },
    ],
  },
  'referral': {'inviteCode': 'FFEEDD0011'},
  'levels': [],
  'events': [],
  'articles': {},
};

class GrowthSite extends FakeSite implements SiteDataService {
  final calls = <({String method, String path, Map<String, dynamic>? body})>[];
  bool checked = false;
  int xp = 0;
  int? claimFailure;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add((method: method, path: path, body: body));
    if (path == '/api/growth/referrals/claim') {
      if (claimFailure != null) {
        throw ApiFailure('邀请暂时无法领取', status: claimFailure);
      }
      xp = 20;
      return {
        'success': true,
        'data': {'state': growthState(checked: checked, xp: xp)},
      };
    }
    if (path == '/api/growth/check-in') {
      checked = true;
      xp += 5;
      return {
        'success': true,
        'data': {
          'state': growthState(checked: checked, xp: xp),
          'award': {'awarded': true, 'xp': 5},
        },
      };
    }
    return {'success': true, 'data': growthState(checked: checked, xp: xp)};
  }
}

Future<RoomController> growthRoom(
  GrowthSite site,
  MemoryStorage storage, {
  bool authed = true,
}) async {
  final room = RoomController(
    storage: storage,
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await room.initialize();
  if (authed) await room.login('alice', 'test-password');
  return room;
}

Future<void> mountGrowth(
  WidgetTester tester,
  RoomController room,
  String path,
) async {
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: SitePage(controller: room, path: path),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'checkin task posts a check-in and refreshes canonical growth state',
    (tester) async {
      final site = GrowthSite(), storage = MemoryStorage();
      final room = await growthRoom(site, storage);
      addTearDown(room.dispose);
      await mountGrowth(tester, room, '/growth');
      final before = site.calls
          .where((c) => c.method == 'GET' && c.path == '/api/growth/me')
          .length;
      await tester.ensureVisible(find.byKey(const Key('growth-task-checkin')));
      await tester.tap(find.byKey(const Key('growth-task-checkin')));
      await tester.pumpAndSettle();
      expect(
        site.calls.where(
          (c) => c.method == 'POST' && c.path == '/api/growth/check-in',
        ),
        hasLength(1),
      );
      expect(
        site.calls
            .where((c) => c.method == 'GET' && c.path == '/api/growth/me')
            .length,
        before + 1,
      );
      expect(find.byKey(const Key('growth-task-checkin')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('growth-check-in')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('5 经验 ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an authenticated invitation link claims normalized code and shows returned state',
    (tester) async {
      final site = GrowthSite(), storage = MemoryStorage();
      final room = await growthRoom(site, storage);
      addTearDown(room.dispose);
      await mountGrowth(tester, room, '/growth?invite=abcdef0123');
      final claims = site.calls
          .where((c) => c.path == '/api/growth/referrals/claim')
          .toList();
      expect(claims, hasLength(1));
      expect(claims.single.method, 'POST');
      expect(claims.single.body, {'code': 'ABCDEF0123'});
      expect(storage.drafts['pending-referral:https://yachiyo.hk'], '');
      expect(find.textContaining('20 经验 ·'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('growth-check-in')));
      await tester.tap(find.byKey(const Key('growth-check-in')));
      await tester.pumpAndSettle();
      expect(
        site.calls.where((c) => c.path == '/api/growth/referrals/claim'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'guest invitation is saved without private requests and claimed after login',
    (tester) async {
      final site = GrowthSite(), storage = MemoryStorage();
      final room = await growthRoom(site, storage, authed: false);
      addTearDown(room.dispose);
      await mountGrowth(tester, room, '/growth?invite=012345abcd');
      expect(
        storage.drafts['pending-referral:https://yachiyo.hk'],
        '012345ABCD',
      );
      expect(site.calls, isEmpty);
      await room.login('alice', 'test-password');
      await tester.pumpAndSettle();
      expect(
        site.calls.where((c) => c.path == '/api/growth/referrals/claim'),
        hasLength(1),
      );
      expect(storage.drafts['pending-referral:https://yachiyo.hk'], '');
      expect(find.textContaining('20 经验 ·'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'native invite share records XP after success and leaves canceled shares untouched',
    (tester) async {
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      var shareResult = '';
      final shares = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            shares.add(call);
            return shareResult;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final site = GrowthSite(), storage = MemoryStorage();
      final room = await growthRoom(site, storage);
      addTearDown(room.dispose);
      await mountGrowth(tester, room, '/growth');
      await tester.ensureVisible(find.byKey(const Key('growth-share-invite')));
      await tester.tap(find.byKey(const Key('growth-share-invite')));
      await tester.pumpAndSettle();
      expect(shares, hasLength(1));
      expect(
        (shares.single.arguments as Map)['text'],
        contains('/register?invite=FFEEDD0011&redirect=%2Fgrowth'),
      );
      expect(
        site.calls.where((c) => c.path == '/api/growth/actions/share'),
        isEmpty,
      );
      shareResult = 'com.example.chosenShareTarget';
      await tester.tap(find.byKey(const Key('growth-share-invite')));
      await tester.pumpAndSettle();
      expect(shares, hasLength(2));
      final recorded = site.calls
          .where((c) => c.path == '/api/growth/actions/share')
          .toList();
      expect(recorded, hasLength(1));
      expect(recorded.single.body, {'platform': 'native'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'temporary referral failure preserves pending code and permanent rejection clears it',
    (tester) async {
      for (final status in [503, 400]) {
        final site = GrowthSite()..claimFailure = status,
            storage = MemoryStorage();
        final room = await growthRoom(site, storage);
        await mountGrowth(tester, room, '/growth?invite=ABCDEF0123');
        expect(
          storage.drafts['pending-referral:https://yachiyo.hk'],
          status == 400 ? '' : 'ABCDEF0123',
        );
        expect(
          site.calls.where((c) => c.path == '/api/growth/referrals/claim'),
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox());
        room.dispose();
      }
    },
  );
}
