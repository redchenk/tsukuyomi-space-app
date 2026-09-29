import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_memory.dart';
import 'package:tsukuyomi_space_app/core/room_reference.dart';
import 'package:tsukuyomi_space_app/core/tts_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

import 'compatible_services_test.dart' show wav;
import 'support/fakes.dart';

void main() {
  for (final provider in [
    'mimo',
    'minimax',
    'elevenlabs',
    'gpt-sovits',
    'openai-compatible',
  ]) {
    test(
      '$provider uses website request contract and decodes speech',
      () async {
        final seen = <http.Request>[];
        final client = TtsClient(
          clientFactory: () => MockClient((request) async {
            seen.add(request);
            expect(request.headers['cookie'], isNull);
            if (request.url.path.startsWith('/set_')) {
              return http.Response('{}', 200);
            }
            final body = request.body.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(request.body) as Map;
            switch (provider) {
              case 'mimo':
                expect(request.headers['api-key'], 'test-tts');
                expect(request.headers['authorization'], isNull);
                expect(body['messages'].last['content'], '你好');
                expect(body['audio'], {'format': 'wav', 'voice': 'voice-id'});
                return http.Response(
                  jsonEncode({
                    'choices': [
                      {
                        'message': {
                          'audio': {'data': base64Encode(wav())},
                        },
                      },
                    ],
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              case 'minimax':
                expect(request.headers['authorization'], 'Bearer test-tts');
                expect(body['text'], '你好');
                expect(body['voice_setting']['voice_id'], 'voice-id');
                expect(body['language_boost'], 'Chinese');
                return http.Response(
                  jsonEncode({
                    'data': {
                      'audio': [
                        73,
                        68,
                        51,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                      ].map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
                    },
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              case 'elevenlabs':
                expect(request.url.path, '/v1/text-to-speech/voice-id');
                expect(request.headers['xi-api-key'], 'test-tts');
                expect(request.headers['authorization'], isNull);
                expect(body, {'text': '你好', 'model_id': 'test-model'});
              case 'gpt-sovits':
                expect(request.method, 'GET');
                expect(
                  request.url.queryParameters['ref_audio_path'],
                  '/voices/yachiyo.wav',
                );
                expect(request.url.queryParameters['text_lang'], 'zh');
                expect(request.url.queryParameters['text'], '你好');
              case 'openai-compatible':
                expect(request.headers['authorization'], 'Bearer test-tts');
                expect(body['input'], '你好');
            }
            return http.Response.bytes(
              wav(),
              200,
              headers: {'content-type': 'audio/wav'},
            );
          }),
        )..siteCookie = 'website-only';
        final settings = RoomSettings(
          ttsUrl: provider == 'elevenlabs'
              ? 'https://provider.example/v1/text-to-speech'
              : 'https://provider.example/tts',
          ttsKey: 'test-tts',
          ttsModel: 'test-model',
          voice: 'voice-id',
          options: {
            'ttsProvider': provider,
            'textLang': 'zh',
            'refAudioPath': '/voices/yachiyo.wav',
            'gptWeightPath': '/models/voice.ckpt',
            'sovitsWeightPath': '/models/voice.pth',
          },
        );
        final audio = await client.synthesize(settings, '你好');
        expect(audio.format, provider == 'minimax' ? 'mp3' : 'wav');
        expect(seen.length, provider == 'gpt-sovits' ? 3 : 1);
        if (provider == 'gpt-sovits') {
          expect(seen[0].url.path, '/set_gpt_weights');
          expect(
            seen[1].url.queryParameters['weights_path'],
            '/models/voice.pth',
          );
        }
      },
    );
  }
  test(
    'TTS site proxy carries account cookie only to the selected website',
    () async {
      final client = TtsClient(
        clientFactory: () => MockClient((r) async {
          expect(r.url.toString(), 'https://site.example/api/tts');
          expect(r.headers['cookie'], 'session=test');
          expect(r.headers['authorization'], isNull);
          expect(jsonDecode(r.body)['apiKey'], 'tts-test');
          return http.Response.bytes(wav(), 200);
        }),
      )..siteCookie = 'session=test';
      await client.synthesize(
        const RoomSettings(
          siteUrl: 'https://site.example',
          ttsUrl: 'https://voice.example/v1',
          ttsKey: 'tts-test',
          options: {'ttsProxy': true},
        ),
        '你好',
      );
    },
  );
  test('all exported website actions have numeric values and run without corrupting model parameters', () {
    expect(RoomReference.rows('actions'), isNotEmpty);
    final animation = RoomAnimation()..ready = true;
    addTearDown(animation.dispose);
    for (final action in RoomReference.rows('actions')) {
      for (final parameter in action['parameters'] as List) {
        expect(
          parameter['value'],
          isA<num>(),
          reason: '${action['id']} ${parameter['id']}',
        );
      }
      animation.clear();
      animation.enqueue({
        'actions': [
          {'id': action['id']},
        ],
        'durationMs': 3000,
      });
      animation.advance(.3);
      expect(animation.parameters.values.every((v) => v.isFinite), isTrue);
    }
  });
  test('guest recall finds names and preferences; excerpt retains a late matching fact', () {
    expect(roomMemoryScore('你还记得我叫什么名字？', '我叫小夜，叫我小夜就好'), greaterThan(0));
    expect(
      roomMemoryScore('我喜欢喝什么？', '我喜欢乌龙茶'),
      greaterThan(roomMemoryScore('我喜欢喝什么？', '今天出门散步')),
    );
    final content = '${'无关记录。' * 250}我喜欢乌龙茶${'无关记录。' * 250}';
    expect(roomMemoryExcerpt(content, '我喜欢喝什么？'), contains('乌龙茶'));
    expect(sensitiveRoomMemory.hasMatch('我的密码是测试值'), isTrue);
  });
  test('guest memory opt out, sensitive text and edited turn replace rather than duplicate', () async {
    final c = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await c.initialize();
    addTearDown(c.dispose);
    final original = ChatTurn(
      id: 'guest-1',
      user: '我喜欢乌龙茶',
      assistant: '记住了',
      createdAt: DateTime.now(),
    );
    await c.workspace.captureGuestTurn(original);
    final count = c.workspace.localMemories.length;
    expect(count, 1);
    await c.workspace.captureGuestTurn(
      ChatTurn.fromJson({...original.toJson(), 'user': '我喜欢绿茶'}),
      replace: true,
    );
    expect(c.workspace.localMemories.length, count);
    expect(c.workspace.localMemories.single['content'], contains('绿茶'));
    await c.workspace.captureGuestTurn(
      ChatTurn.fromJson({
        ...original.toJson(),
        'id': 'guest-2',
        'user': '我的密码是测试值',
      }),
    );
    await c.workspace.captureGuestTurn(
      ChatTurn.fromJson({
        ...original.toJson(),
        'id': 'guest-3',
        'memoryEnabled': false,
      }),
    );
    expect(c.workspace.localMemories.length, count);
  });
}
