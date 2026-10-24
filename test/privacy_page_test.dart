import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/privacy_page.dart';

import 'support/fakes.dart';

class PrivacySite extends FakeSite implements SiteDataService {
  Map<String, dynamic>? record;
  bool fail = false;
  Completer<Map<String, dynamic>>? pending;
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (!path.startsWith('/api/account-deletion')) {
      return {'success': true, 'data': {}};
    }
    if (pending != null && method == 'GET') return pending!.future;
    if (fail) throw const ApiFailure('服务暂不可用');
    if (method == 'POST') {
      // Match the currently deployed backend; newer native policy dates must
      // not make an unchanged deletion request unusable during staged rollout.
      if (!path.endsWith('/cancel') && body?['policyVersion'] != '2026-10-23') {
        throw const ApiFailure('请阅读当前注销说明并确认申请。');
      }
      writes.add(body ?? {});
      record = {
        'id': 'private-reference',
        'status': path.endsWith('/cancel') ? 'cancelled' : 'pending',
        'due_at': '2026-11-21T00:00:00.000Z',
      };
    }
    return {'success': true, 'data': record};
  }
}

Future<RoomController> mount(
  WidgetTester tester,
  PrivacySite site, {
  bool signedIn = true,
  String path = '/delete-account',
}) async {
  tester.view.physicalSize = const Size(390, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final c = RoomController(
    storage: MemoryStorage(),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  if (signedIn) await c.login('alice', 'test-only');
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: PrivacyPage(controller: c, path: path, onGo: (_) {}),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return c;
}

void main() {
  testWidgets(
    'public policy and deletion email are accessible without login at phone width',
    (tester) async {
      await mount(tester, PrivacySite(), signedIn: false);
      expect(find.text('redchenk919@gmail.com'), findsOneWidget);
      expect(find.byKey(const Key('deletion-submit')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'explicit confirmation uses deployed deletion terms, displays receipt and prevents duplicates',
    (tester) async {
      final site = PrivacySite();
      await mount(tester, site);
      var button = tester.widget<FilledButton>(
        find.byKey(const Key('deletion-submit')),
      );
      expect(button.onPressed, isNull);
      await tester.ensureVisible(find.byKey(const Key('deletion-confirm')));
      await tester.tap(find.byKey(const Key('deletion-confirm')));
      await tester.pump();
      button = tester.widget<FilledButton>(
        find.byKey(const Key('deletion-submit')),
      );
      expect(button.onPressed, isNotNull);
      await tester.ensureVisible(find.byKey(const Key('deletion-submit')));
      await tester.tap(find.byKey(const Key('deletion-submit')));
      await tester.pumpAndSettle();
      expect(site.writes.single['confirmation'], 'DELETE_ACCOUNT');
      expect(site.writes.single['policyVersion'], '2026-10-23');
      expect(find.text('等待站长核验'), findsOneWidget);
      expect(find.byKey(const Key('deletion-submit')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('failure is visible and does not claim a request was accepted', (
    tester,
  ) async {
    final site = PrivacySite();
    await mount(tester, site);
    await tester.ensureVisible(find.byKey(const Key('deletion-confirm')));
    await tester.tap(find.byKey(const Key('deletion-confirm')));
    await tester.pump();
    site.fail = true;
    await tester.ensureVisible(find.byKey(const Key('deletion-submit')));
    await tester.tap(find.byKey(const Key('deletion-submit')));
    await tester.pumpAndSettle();
    expect(find.text('服务暂不可用'), findsOneWidget);
    expect(find.text('等待站长核验'), findsNothing);
  });
  testWidgets('late private response is discarded after logout', (
    tester,
  ) async {
    final site = PrivacySite()..pending = Completer<Map<String, dynamic>>();
    final c = await mount(tester, site);
    await c.logout();
    await tester.pump();
    site.pending!.complete({
      'success': true,
      'data': {
        'id': 'old-private-receipt',
        'status': 'pending',
        'due_at': '2026-11-21',
      },
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('old-private-receipt'), findsNothing);
    expect(find.byKey(const Key('deletion-submit')), findsNothing);
  });
  testWidgets('privacy document bundles full policy for offline reading', (
    tester,
  ) async {
    await mount(tester, PrivacySite(), signedIn: false, path: '/privacy');
    expect(find.text('账号与登录'), findsOneWidget);
    expect(find.text('未成年人及政策更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
