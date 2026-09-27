import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/tts_client.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';

Uint8List wav({bool streamingHeader = false}) {
  final bytes = Uint8List(44 + 320);
  final data = ByteData.sublistView(bytes);
  void label(int offset, String value) =>
      bytes.setRange(offset, offset + 4, ascii.encode(value));
  label(0, 'RIFF');
  data.setUint32(
    4,
    streamingHeader ? 0xffffffff : bytes.length - 8,
    Endian.little,
  );
  label(8, 'WAVE');
  label(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, streamingHeader ? 0xffffffff : 320, Endian.little);
  return bytes;
}

void main() {
  test('base URLs, prefixed gateways and complete routes normalize without duplication', () {
    expect(
      compatibleEndpoint('https://example.com').path,
      '/v1/chat/completions',
    );
    expect(
      compatibleEndpoint('https://example.com/v1/').path,
      '/v1/chat/completions',
    );
    expect(
      compatibleEndpoint('https://example.com/api/v4/').path,
      '/api/v4/chat/completions',
    );
    expect(
      compatibleEndpoint(
        'https://example.com/v1/audio/speech/',
        speech: true,
      ).path,
      '/v1/audio/speech',
    );
    expect(
      compatibleEndpoint('https://example.com/v1?tenant=a', speech: true).query,
      'tenant=a',
    );
    expect(
      () => compatibleEndpoint('https://example.com/v1/responses'),
      throwsFormatException,
    );
  });

  test('actual HTTP LLM and TTS contracts use separate keys and decode returned bytes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0;
    final handled = server.listen((request) async {
      calls++;
      final json = jsonDecode(await utf8.decoder.bind(request).join());
      expect(request.method, 'POST');
      if (request.uri.path == '/v1/chat/completions') {
        expect(request.headers.value('authorization'), 'Bearer llm-test-only');
        expect(json['model'], 'test-chat');
        expect(json['stream'], true);
        expect(json['messages'].last['content'], '你好');
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"你好，月读"}}]}\n\n',
        );
        await request.response.flush();
        request.response.write(
          'data: {"choices":[{"delta":{"content":"空间"},"finish_reason":"stop"}]}\n\n',
        );
      } else {
        expect(request.uri.path, '/v1/audio/speech');
        expect(request.headers.value('authorization'), 'Bearer tts-test-only');
        expect(json, {
          'model': 'test-voice',
          'voice': 'alloy',
          'input': '你好，月读空间',
          'response_format': 'wav',
        });
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.add(wav(streamingHeader: true));
      }
      await request.response.close();
    });
    addTearDown(handled.cancel);
    final base = 'http://127.0.0.1:${server.port}/v1';
    final settings = RoomSettings(
      llmUrl: base,
      model: 'test-chat',
      apiKey: 'llm-test-only',
      demo: false,
      ttsUrl: base,
      ttsModel: 'test-voice',
      ttsKey: 'tts-test-only',
    );
    final llm = LlmClient();
    final reply = await llm.reply(settings, [], '你好').join();
    expect(reply, '你好，月读空间');
    final audio = await TtsClient().synthesize(settings, reply);
    expect(audio.format, 'wav');
    expect(WavEnvelope.parse(audio.bytes).duration.inMilliseconds, 10);
    expect(ByteData.sublistView(audio.bytes).getUint32(40, Endian.little), 320);
    expect(calls, 2);
  });

  test(
    'JSON-only compatible LLM responses work even when streaming is requested',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'JSON reply'},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
        await request.response.close();
      });
      expect(
        await LlmClient()
            .reply(
              RoomSettings(
                llmUrl: 'http://127.0.0.1:${server.port}',
                model: 'json',
                demo: false,
              ),
              [],
              'test',
            )
            .join(),
        'JSON reply',
      );
    },
  );

  test(
    'provider auth failures are actionable and never echo provider secrets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 401;
        request.response.write('sensitive-provider-error');
        await request.response.close();
      });
      await expectLater(
        TtsClient().synthesize(
          RoomSettings(ttsUrl: 'http://127.0.0.1:${server.port}'),
          'test',
        ),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('API Key') &&
                !e.toString().contains('sensitive-provider'),
          ),
        ),
      );
    },
  );

  test('audio format persists separately from keys', () {
    const settings = RoomSettings(
      ttsFormat: 'mp3',
      apiKey: 'secret',
      ttsKey: 'other-secret',
    );
    final encoded = jsonEncode(settings.toJson());
    expect(encoded, isNot(contains('secret')));
    expect(RoomSettings.fromJson(jsonDecode(encoded)).ttsFormat, 'mp3');
  });
}
