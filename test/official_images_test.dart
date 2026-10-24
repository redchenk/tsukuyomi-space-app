import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/model_runtime.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/official_api.dart';
import 'package:tsukuyomi_space_app/core/room_files.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/model_runtime_panel.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';
import 'package:tsukuyomi_space_app/features/site/payments_page.dart';

import 'support/fakes.dart';
import 'support/payment_site.dart';
import 'support/site_capture_fonts.dart';

const imageSettings = RoomSettings(
  llmUrl: 'https://yachiyo.hk/official-api/v1/chat/completions',
  model: 'vision-fixture',
  options: {'memoryEnabled': false, 'knowledgeEnabled': false},
);
const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4RBCAwBRcwH+conGc8AAAAASUVORK5CYII=';

class ImageSite extends PaymentFixtureSite {
  bool vision = true;
  final uploads = <Map<String, dynamic>>[];
  @override
  Map<String, dynamic> get dashboard => {
    ...super.dashboard,
    'models': [
      {
        'id': 'vision-fixture',
        'provider': 'fixture',
        'enabled': true,
        'max_output_tokens': 2048,
        'capabilities': {'vision': vision},
      },
      {
        'id': 'text-fixture',
        'provider': 'fixture',
        'enabled': true,
        'max_output_tokens': 1024,
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/room/chat/images') {
      uploads.add({...body!});
      return {
        'data': {'id': 'saved-image', ...body},
      };
    }
    return super.request(site, method, path, body);
  }
}

Future<RoomController> createController(
  ImageSite site, {
  ChatService? chat,
  RoomSettings settings = imageSettings,
}) async {
  final c = RoomController(
    storage: MemoryStorage()..value = settings,
    site: site,
    chat: chat ?? FakeChat(),
    voice: SilentVoice(),
  );
  await c.initialize();
  await c.login('alice', 'fixture-password');
  c.pause();
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final rejection in ['', 'unsupported', 'account-changed']) {
    test(
      'official image turn from attachment through SSE and history: $rejection',
      () async {
        final site = ImageSite();
        // An installed app may still have the old text-only declaration cached.
        final stale = officialRoomSettings(
          imageSettings,
          (ImageSite()..vision = false).dashboard,
        );
        final posts = <http.Request>[];
        final llm = LlmClient(
          clientFactory: () => MockClient((request) async {
            if (request.method == 'GET') {
              final data = site.dashboard;
              if (rejection == 'account-changed') {
                data['me'] = {
                  'site_user_id': 'bob',
                  'account_id': 'official-bob',
                };
              }
              return http.Response(jsonEncode(data), 200);
            }
            posts.add(request);
            return http.Response(
              [
                    {
                      'choices': [
                        {
                          'delta': {'content': '看见图片了。'},
                          'finish_reason': null,
                        },
                      ],
                    },
                    {
                      'choices': [
                        {'delta': {}, 'finish_reason': 'stop'},
                      ],
                      'usage': {
                        'prompt_tokens': 10,
                        'completion_tokens': 5,
                        'total_tokens': 15,
                      },
                    },
                    '[DONE]',
                  ]
                  .map(
                    (part) =>
                        'data: ${part is String ? part : jsonEncode(part)}\n\n',
                  )
                  .join(),
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            );
          }),
        );
        final c = await createController(site, chat: llm, settings: stale);
        site.vision = rejection != 'unsupported';
        final image = await prepareRoomImage(base64Decode(png), 'fixture.png');
        await c.attach(image);
        await c.send('看看这张图片');
        await c.sync();
        c.pause();
        if (rejection.isEmpty) {
          expect(c.error, isEmpty);
          expect(posts, hasLength(1));
          final request = posts.single;
          expect(request.url.toString(), imageSettings.llmUrl);
          expect(request.headers['Cookie'], site.cookie);
          expect(
            request.headers['X-Official-Expected-Account'],
            'official-alice',
          );
          expect(request.headers['Authorization'], isNull);
          final body = jsonDecode(request.body) as Map;
          expect(body['stream'], true);
          expect(body['stream_options'], {'include_usage': true});
          final parts = (body['messages'] as List).last['content'] as List;
          expect(
            parts
                .where((p) => p['type'] == 'image_url')
                .single['image_url']['url'],
            startsWith('data:image/png;base64,'),
          );
          expect(
            parts.where((p) => p['type'] == 'text').single['text'],
            '看看这张图片',
          );
          expect(c.turns.single.assistant, '看见图片了。');
          expect(c.turns.single.image?['id'], 'saved-image');
          expect(c.turns.single.pending, false);
          expect(site.uploads.single['dataUrl'], image['dataUrl']);
          expect(c.attachment, isNull);
        } else {
          expect(
            c.error,
            contains(rejection == 'unsupported' ? '不支持图片' : '账号已变化'),
          );
          expect(posts, isEmpty);
          expect(site.uploads, isEmpty);
          expect(c.turns, isEmpty);
          expect(c.attachment?['dataUrl'], image['dataUrl']);
        }
      },
    );
  }

  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets(
      'official model selection, saved capabilities and price guidance at $width',
      (tester) async {
        const capture = bool.fromEnvironment('CAPTURE_UI');
        if (capture) await tester.runAsync(loadSiteCaptureFonts);
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = await createController(ImageSite());
        Widget app(Widget page) => RepaintBoundary(
          key: const ValueKey('image-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: capture ? 'PingFang SC' : null),
            home: page,
          ),
        );
        await tester.pumpWidget(app(RoomSettingsPage(controller: c)));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('刷新直供模型'));
        await tester.tap(find.text('刷新直供模型'));
        await tester.pumpAndSettle();
        expect(find.textContaining('支持文字、图片与工具调用'), findsOneWidget);
        final picker = find.byKey(
          const ValueKey('official-model-vision-fixture'),
        );
        await tester.ensureVisible(picker);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('text-fixture · 文字').last);
        await tester.pumpAndSettle();
        expect(find.textContaining('当前模型支持文字聊天'), findsOneWidget);
        RoomSettings displayed() => tester
            .widget<ModelRuntimePanel>(find.byType(ModelRuntimePanel))
            .settings;
        expect(ModelRuntime(displayed()).unsupported('image'), true);
        // Manual model input also refreshes the displayed capability, like selection.
        final model = find.byKey(const Key('setting-model'));
        await tester.ensureVisible(model);
        await tester.enterText(model, 'vision-fixture');
        await tester.pumpAndSettle();
        expect(ModelRuntime(displayed()).unsupported('image'), false);
        await tester.tap(find.text('保存全部'));
        await tester.pumpAndSettle();
        expect(c.settings.model, 'vision-fixture');
        expect(ModelRuntime(c.settings).unsupported('image'), false);
        if (capture) {
          await tester.ensureVisible(find.textContaining('支持文字、图片与工具调用'));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary = tester.firstRenderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('image-capture')),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'artifacts/official-images-20261024/settings-${width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(app(PaymentsPage(controller: c, onGo: (_) {})));
        await tester.pumpAndSettle();
        expect(find.textContaining('fixture · 文字与图片 · 最多输出'), findsOneWidget);
        expect(find.textContaining('Room 可直接发送图片'), findsOneWidget);
        expect(tester.takeException(), isNull);
        c.pause();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
