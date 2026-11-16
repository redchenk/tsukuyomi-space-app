import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/site_repository.dart';
import 'package:tsukuyomi_space_app/features/drift/drift_page.dart';
import 'package:tsukuyomi_space_app/features/drift/drift_submissions.dart';
import 'package:tsukuyomi_space_app/features/game/gomoku_page.dart';
import 'package:tsukuyomi_space_app/features/pixel/pixel_document.dart';
import 'package:tsukuyomi_space_app/features/site/official_services_manager.dart';
import 'package:tsukuyomi_space_app/features/site/mail_campaign_manager.dart';
import 'package:tsukuyomi_space_app/features/site/management_service.dart';

import 'site_archive_pages_test.dart' show ArchiveSite, archiveController;
import 'support/fakes.dart';
import 'support/site_capture_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('SYNC_CAPTURE');
  if (capture) setUpAll(loadSiteCaptureFonts);
  test('English public reads are host-limited; writes and sessions keep original routes', () async {
    final seen = <String>[];
    final site = SiteClient(
      client: MockClient((r) async {
        seen.add('${r.method} ${r.url.host}${r.url.path}');
        return http.Response('{"success":true,"data":{}}', 200);
      }),
    );
    addTearDown(site.dispose);
    await site.request(
      'https://tsukuyomi-space.com',
      'GET',
      '/api/live/123/articles',
    );
    await site.request('https://tsukuyomi-space.com', 'GET', '/api/auth/me');
    await site.request('https://tsukuyomi-space.com', 'POST', '/api/messages', {
      'content': 'original',
    });
    await site.request('https://yachiyo.hk', 'GET', '/api/articles');
    site.contentTranslation = () => false;
    await site.request('https://tsukuyomi-space.com', 'GET', '/api/articles');
    expect(seen, [
      'GET tsukuyomi-space.com/en-api/live/123/articles',
      'GET tsukuyomi-space.com/api/auth/me',
      'POST tsukuyomi-space.com/api/messages',
      'GET yachiyo.hk/api/articles',
      'GET tsukuyomi-space.com/api/articles',
    ]);
  });
  test(
    'translation cache partition does not change the draft identity',
    () async {
      var enabled = true;
      final site = SiteClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'success': true,
              'data': {'title': enabled ? 'English' : '原文'},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      )..contentTranslation = () => enabled;
      addTearDown(site.dispose);
      final repo = SiteRepository(
        api: site,
        storage: MemoryStorage(),
        site: () => 'https://tsukuyomi-space.com',
        accountId: () => null,
      );
      final identity = repo.identityScope;
      await repo.read('/api/articles');
      enabled = false;
      expect(await repo.cached('/api/articles'), isNull);
      expect(repo.identityScope, identity);
      await repo.read('/api/articles');
      enabled = true;
      expect((await repo.cached('/api/articles'))!.data['title'], 'English');
    },
  );
  test(
    'a pinch cancels the pending stroke without destroying earlier redo',
    () {
      final doc = PixelDocument();
      addTearDown(doc.dispose);
      doc.beginStroke(2, 2);
      doc.endStroke();
      doc.undo();
      expect(doc.canRedo, isTrue);
      doc.beginStroke(3, 3);
      doc.continueStroke(20, 20);
      doc.cancelStroke();
      expect(doc.paintedCount, 0);
      expect(doc.canRedo, isTrue);
      doc.redo();
      expect(doc.paintedCount, 1);
      doc.chooseTool(PixelTool.fill);
      doc.beginStroke(0, 0);
      doc.cancelStroke();
      expect(doc.paintedCount, 1);
    },
  );
  test('private letters persist only a receipt and retry the same immutable submission', () async {
    final storage = MemoryStorage(), s = DriftSubmissions(MemoryStorage());
    final one = DriftSubmissions(storage);
    final a = await one.prepare('site:alice:daily', {
      'content': 'private letter',
      'promptDate': '2026-11-16',
    });
    final b = await DriftSubmissions(storage).prepare('site:alice:daily', {
      'content': 'private letter',
      'promptDate': '2026-11-16',
    });
    expect(a['requestId'], b['requestId']);
    expect(storage.drafts.values.join(), isNot(contains('private letter')));
    expect(
      (await s.prepare('site:bob:daily', {
        'content': 'private letter',
      }))['requestId'],
      isNot(a['requestId']),
    );
  });
  test('DeepSeek runs through the real LLM pipeline and retains signed continuation', () async {
    var calls = 0;
    final llm = LlmClient(
      clientFactory: () => MockClient((r) async {
        calls++;
        final body = jsonDecode(r.body);
        expect(r.url.path, '/chat/completions');
        expect(
          body['tools'].any((t) => t['type'] == 'deepseek_web_search'),
          isTrue,
        );
        expect(r.headers.containsKey('Cookie'), isFalse);
        return http.Response(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {
                  'content': '你好',
                  'server_tool_calls': [
                    {'signature': 'signed'},
                  ],
                },
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }),
    );
    const settings = RoomSettings(
      llmUrl: 'https://api.deepseek.com/v1/chat/completions',
      model: 'deepseek-flash',
      apiKey: 'fixture',
      options: {'deepseekSearch': true},
    );
    expect(await llm.reply(settings, [], '你好').join(), '你好');
    expect(calls, 1);
    expect(llm.lastDeepseek?['server_tool_calls'], [
      {'signature': 'signed'},
    ]);
    llm.cancel();
  });
  for (final width in [320.0, 1280.0]) {
    for (final route in ['drift', 'gomoku', 'services', 'mail']) {
      testWidgets('$route fits $width and leaves no rendering exceptions', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final site = ArchiveSite((method, path, body) async {
          dynamic data = <String, dynamic>{};
          if (path.startsWith('/api/drift?')) {
            data = {'items': [], 'page': 1, 'totalPages': 1};
          }
          if (path.endsWith('daily-prompt')) {
            data = {'id': 1, 'date': '2026-11-16', 'text': '今天让你微笑的事是什么？'};
          }
          if (path == '/api/admin/official-services/tts') {
            data = {
              'revision': 1,
              'primary': {
                'enabled': true,
                'language': 'ja',
                'protocol': 'GPT-SoVITS',
              },
              'fish': {
                'enabled': true,
                'language': 'ja',
                'voice': 'a' * 32,
                'model': 's2-pro',
                'models': ['s2-pro'],
                'hasKey': true,
              },
              'languages': ['ja', 'zh'],
              'availableModels': ['s2-pro', 's1'],
            };
          }
          if (path == '/api/admin/mail-campaigns') {
            data = {'configured': true, 'campaigns': []};
          }
          if (path.startsWith('/api/admin/mail-campaigns/recipients')) {
            data = {
              'items': [
                {'id': 'a', 'email': 'fixture@example.test', 'username': '旅人'},
              ],
              'page': 1,
              'totalPages': 1,
              'total': 1,
            };
          }
          return {'success': true, 'data': data};
        });
        final c = await archiveController(site, account: 'alice');
        addTearDown(c.dispose);
        final api = ManagementService(
          site,
          c.settings.siteUrl,
          terminalSession: true,
        );
        final child = switch (route) {
          'drift' => DriftPage(controller: c, onGo: (_) {}),
          'gomoku' => GomokuPage(controller: c, onGo: (_) {}),
          'services' => Scaffold(
            body: SingleChildScrollView(
              child: OfficialServicesManager(api: api, onGo: (_) {}),
            ),
          ),
          _ => Scaffold(
            body: SingleChildScrollView(child: MailCampaignManager(api: api)),
          ),
        };
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(key: const Key('capture'), child: child),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            for (final image in tester.widgetList<Image>(find.byType(Image))) {
              if (image.image is AssetImage) {
                await precacheImage(
                  image.image,
                  tester.element(find.byKey(const Key('capture'))),
                );
              }
            }
          });
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'artifacts/native-sync-20261116/$route-${width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
