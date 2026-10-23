import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/official_tts.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';
import 'package:tsukuyomi_space_app/features/site/official_tts_history.dart';

import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

class StatusSite extends FakeSite implements SiteDataService {
  bool online = true;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    calls.add('$method $path');
    if (method != 'GET' || path != '/api/tts/official/status') {
      throw StateError('A settings/readiness visit must not create jobs');
    }
    return {
      'success': true,
      'data': {
        'online': online,
        'priceAtoms': '50000000',
        'maxCharacters': 1000,
        'retentionHours': 24,
        'language': 'ja',
      },
    };
  }
}

Future<RoomController> controller(
  StatusSite site,
  MemoryStorage storage, {
  bool login = true,
}) async {
  final c = RoomController(
    storage: storage,
    site: site,
    chat: FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  if (login) await c.login('alice', 'fixture-password');
  c.pause();
  return c;
}

Future<void> screenshot(WidgetTester tester, String name) async {
  final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('artifacts/official-tts-20261023/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'official voice saves without URL/model/key and without synthesis at $width',
      (tester) async {
        const capture = bool.fromEnvironment('CAPTURE_UI');
        if (capture) await tester.runAsync(loadSiteCaptureFonts);
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final site = StatusSite(), storage = MemoryStorage();
        final c = await controller(site, storage);
        addTearDown(c.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('capture'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                useMaterial3: true,
                fontFamily: capture ? 'PingFang SC' : null,
              ),
              home: RoomSettingsPage(controller: c, initialSection: 'tts'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('算力在线'), findsOneWidget);
        final official = find.byKey(const ValueKey('official-tts-preset'));
        await tester.ensureVisible(official);
        await tester.tap(official);
        await tester.pumpAndSettle();
        for (final field in ['ttsUrl', 'ttsKey', 'ttsModel', 'voice']) {
          expect(find.byKey(Key('setting-$field')), findsNothing);
        }
        expect(find.text('保存并试听 · ¥0.05'), findsOneWidget);
        if (capture) {
          await tester.ensureVisible(
            find.byKey(const ValueKey('official-tts-status')),
          );
          await tester.pumpAndSettle();
          await screenshot(tester, 'official-settings-${width.toInt()}-status');
          await tester.ensureVisible(find.text('保存并试听 · ¥0.05'));
          await tester.pumpAndSettle();
          await screenshot(
            tester,
            'official-settings-${width.toInt()}-controls',
          );
        }
        await tester.tap(find.text('保存全部'));
        await tester.pumpAndSettle();
        expect(storage.value.option('ttsProvider'), 'official');
        expect(storage.value.option('officialTtsAccount'), 'alice');
        expect(storage.value.option('officialTtsOrigin'), 'https://yachiyo.hk');
        expect(storage.value.speak, isTrue);
        expect(storage.value.ttsUrl, isEmpty);
        expect(storage.value.ttsKey, isEmpty);
        expect(
          site.calls.every((call) => call == 'GET /api/tts/official/status'),
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'guest cannot select the official preset or start a charged preview',
    (tester) async {
      final site = StatusSite(), storage = MemoryStorage();
      final c = await controller(site, storage, login: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomSettingsPage(controller: c, initialSection: 'tts'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ActionChip>(
              find.byKey(const ValueKey('official-tts-preset')),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('ttsProvider:openai-compatible')),
      );
      await tester.tap(
        find.byKey(const ValueKey('ttsProvider:openai-compatible')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('官方直供 · 八千代语音').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '保存并试听 · ¥0.05'),
            )
            .onPressed,
        isNull,
      );
      expect(site.calls.every((call) => call.startsWith('GET ')), true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'offline selection can be saved but paid audition stays disabled',
    (tester) async {
      final site = StatusSite()..online = false;
      final storage = MemoryStorage()
        ..value = const RoomSettings(
          demo: true,
          speak: true,
          options: {'ttsProvider': 'official'},
        );
      final c = await controller(site, storage);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomSettingsPage(controller: c, initialSection: 'tts'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('算力离线'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '保存并试听 · ¥0.05'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('仅保存设置'));
      await tester.tap(find.text('仅保存设置'));
      await tester.pumpAndSettle();
      expect(storage.value.option('officialTtsAccount'), 'alice');
      expect(storage.value.option('ttsProvider'), 'official');
      expect(tester.takeException(), isNull);
      expect(site.calls.every((call) => call.startsWith('GET ')), true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saving after account switch explicitly binds official voice to the new account',
    (tester) async {
      final site = StatusSite(), storage = MemoryStorage();
      final c = await controller(site, storage);
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RoomSettingsPage(controller: c, initialSection: 'tts'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('official-tts-preset')),
      );
      await tester.tap(find.byKey(const ValueKey('official-tts-preset')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存全部'));
      await tester.pumpAndSettle();
      expect(storage.value.option('officialTtsAccount'), 'alice');
      await c.logout();
      await c.login('bob', 'fixture-password');
      c.pause();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('仅保存设置'));
      await tester.tap(find.text('仅保存设置'));
      await tester.pumpAndSettle();
      expect(storage.value.option('officialTtsAccount'), 'bob');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'private voice history drops an old account response and shows exact current charges',
    (tester) async {
      final site = StatusSite(),
          storage = MemoryStorage()..value = const RoomSettings(demo: false);
      final c = await controller(site, storage);
      addTearDown(c.dispose);
      final alice = Completer<http.Response>(), entered = Completer<void>();
      final client = OfficialTtsClient(
        site: site,
        clientFactory: () => MockClient((request) async {
          expectSync(request.url.path, '/api/tts/official/jobs');
          if (request.headers['x-tts-account'] == 'alice') {
            if (!entered.isCompleted) entered.complete();
            return alice.future;
          }
          return http.Response(
            jsonEncode({
              'success': true,
              'data': [
                {
                  'id': 'bob-voice',
                  'state': 'ready',
                  'chargedAtoms': '100000000',
                  'createdAt': 1792762352153,
                },
              ],
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficialTtsHistory(controller: c, client: client),
          ),
        ),
      );
      await tester.pump();
      expect(entered.isCompleted, true);
      await c.logout();
      await c.login('bob', 'fixture-password');
      c.pause();
      await tester.pumpAndSettle();
      expect(
        find.text('八千代语音 · ¥0.10'),
        findsOneWidget,
        reason:
            'account=${c.account?.id}, verified=${c.sessionVerified}; ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}',
      );
      alice.complete(
        http.Response(
          jsonEncode({
            'success': true,
            'data': [
              {
                'id': 'alice-voice',
                'state': 'ready',
                'chargedAtoms': '50000000',
                'createdAt': 1792762352153,
              },
            ],
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('八千代语音 · ¥0.05'), findsNothing);
      expect(find.text('八千代语音 · ¥0.10'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
