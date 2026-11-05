import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_chat_settings.dart';
import 'package:tsukuyomi_space_app/core/fish_audio.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/tts_client.dart';
import 'package:tsukuyomi_space_app/core/official_tts.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/settings/settings_page.dart';

import 'support/fakes.dart';

void main() {
  final card = RoomChatSettings.importCard(
    jsonEncode({
      'spec': 'chara_card_v2',
      'data': {
        'name': 'fixture',
        'personality': 'CARD_STYLE',
        'system_prompt': 'NEVER_SYSTEM',
        'mes_example': 'NEVER_HISTORY',
        'character_book': {
          'entries': [
            {
              'id': 1,
              'keys': ['测试'],
              'content': 'WORLD_FACT',
            },
            {
              'id': 2,
              'constant': true,
              'content': 'SPOILER_FACT',
              'extensions': {'tsukuyomi_spoiler': true},
            },
          ],
        },
      },
    }),
  );
  test(
    'card/world-book switches and account isolation reach actual LLM requests',
    () async {
      final requests = <String>[];
      final client = LlmClient(
        clientFactory: () => MockClient((request) async {
          requests.add(
            jsonDecode(request.body)['messages'][0]['content'] as String,
          );
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '收到。'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      )..siteAccountId = 'alice';
      RoomSettings settings(bool reference, bool world) => RoomSettings(
        demo: false,
        llmUrl: 'https://fixture.example/v1/chat/completions',
        model: 'fixture',
        apiKey: 'fixture',
        options: {
          'roomDialogueByAccount': {
            RoomChatSettings.scope('https://yachiyo.hk', 'alice'): {
              'reference': card,
              'referenceEnabled': reference,
              'worldBookEnabled': world,
              'spoiler': 'avoid',
              'userPersona': 'ACCOUNT_PERSONA',
            },
          },
        },
      );
      for (final switches in [
        (true, true),
        (false, true),
        (true, false),
        (false, false),
      ]) {
        await client.reply(settings(switches.$1, switches.$2), [], '测试').join();
        expect(requests.last.contains('CARD_STYLE'), switches.$1);
        expect(requests.last.contains('WORLD_FACT'), switches.$2);
        expect(requests.last, isNot(contains('SPOILER_FACT')));
        expect(requests.last, isNot(contains('NEVER_SYSTEM')));
        expect(requests.last, isNot(contains('NEVER_HISTORY')));
        expect(requests.last, contains('ACCOUNT_PERSONA'));
      }
      client.siteAccountId = 'bob';
      await client.reply(settings(true, true), [], '测试').join();
      for (final private in ['CARD_STYLE', 'WORLD_FACT', 'ACCOUNT_PERSONA']) {
        expect(requests.last, isNot(contains(private)));
      }
      client.cancel();
    },
  );
  for (final proxy in [false, true]) {
    test(
      'Fish request carries model, voice, Japanese text and emotion with proxy=$proxy',
      () async {
        final client = TtsClient(
          clientFactory: () => MockClient((request) async {
            final body = jsonDecode(request.body);
            if (proxy) {
              expect(request.url.host, 'yachiyo.hk');
              expect(body['provider'], 'fish-audio');
              expect(body['emotion'], 'calm');
              expect(request.headers['model'], isNull);
            } else {
              expect(request.url.toString(), FishAudio.endpoint);
              expect(request.headers['model'], 'drama-3');
              expect(body['text'], '[calm] こんにちは。');
              expect(body['reference_id'], FishAudio.voice);
            }
            return http.Response.bytes(
              [0x49, 0x44, 0x33, 0],
              200,
              headers: {'content-type': 'audio/mpeg'},
            );
          }),
        );
        final audio = await client.synthesize(
          RoomSettings(
            ttsUrl: FishAudio.endpoint,
            ttsKey: 'fixture',
            ttsModel: 'drama-3',
            voice: FishAudio.voice,
            options: {
              'ttsProvider': 'fish-audio',
              'ttsProxy': proxy,
              'fishStyle': 'calm',
              'textLang': 'ja',
            },
          ),
          'こんにちは。',
        );
        expect(audio.format, 'mp3');
        client.cancel();
      },
    );
  }
  test('official Fish selects capability and separates replay identity by model/emotion', () async {
    final site = FakeSite()..cookie = 'fixture';
    final posts = <Map<String, dynamic>>[];
    final keys = <String>{};
    final client = OfficialTtsClient(
      site: site,
      clientFactory: () => MockClient((request) async {
        Map<String, dynamic> data;
        if (request.url.path.endsWith('/status')) {
          expect(request.url.queryParameters['engine'], 'fish-audio');
          data = {
            'online': true,
            'supportsEmotion': true,
            'language': 'ja',
            'models': ['drama-3', 's2.1-pro'],
          };
        } else if (request.method == 'POST') {
          final body = Map<String, dynamic>.from(jsonDecode(request.body));
          posts.add(body);
          keys.add(body['requestKey'] as String);
          expect(body['engine'], 'fish-audio');
          data = {'id': 'fish_${posts.length}', 'state': 'ready'};
        } else if (request.url.path.endsWith('/audio')) {
          return http.Response.bytes(
            [0x49, 0x44, 0x33, 0],
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        } else {
          data = {'id': request.url.pathSegments.last, 'state': 'ready'};
        }
        return http.Response(jsonEncode({'success': true, 'data': data}), 200);
      }),
    );
    RoomSettings settings(String model, String emotion) => RoomSettings(
      options: {
        'ttsProvider': 'official',
        'officialEngine': 'fish-audio',
        'officialTtsAccount': 'alice',
        'officialTtsOrigin': 'https://yachiyo.hk',
        'officialFishModel': model,
        'fishStyle': emotion,
      },
    );
    await client.synthesize(settings('drama-3', 'calm'), 'こんにちは。');
    await client.synthesize(settings('drama-3', 'calm'), 'こんにちは。');
    expect(posts.length, 1);
    await client.synthesize(settings('s2.1-pro', 'happy'), 'こんにちは。');
    expect(posts.length, 2);
    expect(keys.length, 2);
    expect(posts.last['fishModel'], 's2.1-pro');
    expect(posts.last['emotion'], 'happy');
    client.cancel();
  });
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('native hub and category drafts survive at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
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
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(home: RoomSettingsPage(controller: c)),
      );
      await tester.pumpAndSettle();
      for (final id in roomSections.keys) {
        expect(find.byKey(Key('settings-category-$id')), findsOneWidget);
      }
      expect(find.text('保存修改'), findsNothing);
      if (width == 390) {
        expect(
          tester
              .getBottomLeft(find.byKey(const Key('settings-category-debug')))
              .dy,
          lessThan(844),
        );
      }
      await tester.tap(find.byKey(const Key('settings-category-knowledge')));
      await tester.pumpAndSettle();
      final persona = find.widgetWithText(TextFormField, '希望八千代怎样认识你');
      await tester.ensureVisible(persona);
      await tester.enterText(persona, '未保存的介绍');
      await tester.pump();
      await tester.tap(find.text('全部设置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-category-tts')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部设置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-category-knowledge')));
      await tester.pumpAndSettle();
      expect(find.text('未保存的介绍'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(RoomChatSettings.read(c.settings, null)['userPersona'], '未保存的介绍');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
