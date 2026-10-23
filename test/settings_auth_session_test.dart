import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_navigation.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import 'official_payments_test.dart' show dashboard;
import 'support/fakes.dart';

http.Response reply(Object? data, {String? cookie}) => http.Response(
  jsonEncode({'success': true, 'data': data}),
  200,
  headers: {'content-type': 'application/json', 'set-cookie': ?cookie},
);

Future<RoomController> signedIn({
  required bool demo,
  bool Function()? rejectMe,
}) async {
  final site = SiteClient(
    client: MockClient((request) async {
      if (request.url.path == '/api/auth/login') {
        return reply({
          'user': {'id': 'alice', 'username': 'Alice'},
        }, cookie: 'tsukuyomi_session=fixture; HttpOnly; Path=/');
      }
      if (request.url.path == '/api/auth/me') {
        if (rejectMe?.call() ?? false) {
          return http.Response('{"success":false,"message":"expired"}', 401);
        }
        expect(
          request.headers['Cookie'],
          contains('tsukuyomi_session=fixture'),
        );
        return reply({'id': 'alice', 'username': 'Alice'});
      }
      if (request.url.path == '/api/tts/official/status') {
        return reply({
          'online': true,
          'language': 'ja',
          'priceAtoms': '50000000',
        });
      }
      if (request.url.path == '/official-api/api/dashboard') {
        expect(
          request.headers['Cookie'],
          contains('tsukuyomi_session=fixture'),
        );
        return http.Response(
          jsonEncode(dashboard()),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/api/room/chat') return reply([]);
      if (request.url.path == '/api/room/memory/events') {
        return http.Response(
          '',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      throw StateError(
        'Unexpected request: ${request.method} ${request.url.path}',
      );
    }),
  );
  final c = RoomController(
    storage: MemoryStorage()
      ..value = RoomSettings(
        demo: demo,
        llmUrl: 'https://yachiyo.hk/official-api/v1/chat/completions',
        model: 'deepseek-chat',
      ),
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  await c.login('alice@example.com', 'fixture-password');
  c.pause();
  return c;
}

void main() {
  for (final demo in [false, true]) {
    testWidgets('password login can save official voice with demo=$demo', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await signedIn(demo: demo);
      addTearDown(c.dispose);
      expect(c.sessionVerified, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomSettingsPage(controller: c, initialSection: 'tts'),
        ),
      );
      await tester.pumpAndSettle();
      final preset = find.byKey(const ValueKey('official-tts-preset'));
      await tester.ensureVisible(preset);
      await tester.tap(preset);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存全部'));
      await tester.pumpAndSettle();
      expect(c.settings.option('ttsProvider'), 'official');
      expect(c.settings.option('officialTtsAccount'), 'alice');
      expect(c.sessionVerified, isTrue);
      expect(c.sessionExpired, isFalse);
      expect(c.settings.demo, demo);
      expect(find.text('请先登录月读空间，再使用站内直供'), findsNothing);
      expect(find.text('所有修改已保存'), findsWidgets);
      expect(tester.takeException(), isNull);
      c.pause();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('password login can leave demo using official model settings', (
    tester,
  ) async {
    final c = await signedIn(demo: true);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RoomSettingsPage(controller: c, initialSection: 'llm'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('刷新直供模型'));
    await tester.tap(find.text('刷新直供模型'));
    await tester.pumpAndSettle();
    expect(find.text('请先登录月读空间，再使用站内直供'), findsNothing);
    await tester.tap(find.text('保存全部'));
    await tester.pumpAndSettle();
    expect(c.settings.demo, isFalse);
    expect(c.settings.usesOfficialApi, isTrue);
    expect(c.sessionVerified, isTrue);
    c.pause();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settings avatar opens the account page after password login', (
    tester,
  ) async {
    final c = await signedIn(demo: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        routes: {'/user': (_) => const Scaffold(body: Text('ACCOUNT_PAGE'))},
        home: RoomSettingsPage(controller: c, initialSection: 'tts'),
      ),
    );
    await tester.pumpAndSettle();
    final nav = tester.widget<RoomNavigation>(find.byType(RoomNavigation));
    nav.onAccount!();
    await tester.pumpAndSettle();
    expect(find.text('ACCOUNT_PAGE'), findsOneWidget);
    expect(find.byKey(const Key('auth-submit')), findsNothing);
    expect(c.sessionVerified, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final expired in [false, true]) {
    testWidgets('settings avatar still requests login for expired=$expired', (
      tester,
    ) async {
      final c = await signedIn(demo: true);
      addTearDown(c.dispose);
      if (expired) {
        c.expireSession();
      } else {
        await c.logout();
      }
      await tester.pumpWidget(
        MaterialApp(
          routes: {'/user': (_) => const Scaffold(body: Text('ACCOUNT_PAGE'))},
          home: RoomSettingsPage(controller: c, initialSection: 'tts'),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<RoomNavigation>(find.byType(RoomNavigation)).onAccount!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-submit')), findsOneWidget);
      expect(find.text('ACCOUNT_PAGE'), findsNothing);
      expect(c.sessionVerified, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test(
    'a verified imported session authorizes official services immediately',
    () async {
      final c = await signedIn(demo: true);
      addTearDown(c.dispose);
      await c.logout();
      await c.acceptSiteSession(
        'https://yachiyo.hk',
        'tsukuyomi_session=fixture',
      );
      c.pause();
      expect(c.account?.id, 'alice');
      expect(c.sessionVerified, isTrue);
      expect(c.sessionExpired, isFalse);
    },
  );

  test('failed session import preserves the verified password login', () async {
    var reject = false;
    final c = await signedIn(demo: true, rejectMe: () => reject);
    addTearDown(c.dispose);
    reject = true;
    await expectLater(
      c.acceptSiteSession('https://yachiyo.hk', 'tsukuyomi_session=other'),
      throwsA(isA<ApiFailure>()),
    );
    expect(c.account?.id, 'alice');
    expect(c.site.cookie, 'tsukuyomi_session=fixture');
    expect(c.sessionVerified, isTrue);
    expect(c.sessionExpired, isFalse);
    expect(
      (c.storage as MemoryStorage).secrets['session.https://yachiyo.hk'],
      'tsukuyomi_session=fixture',
    );
  });
}
