import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/deepseek.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_voice_input.dart';

const own = RoomSettings(
  llmUrl: 'https://api.deepseek.com/v1/chat/completions',
  model: 'deepseek-flash',
  apiKey: 'test-key',
);
void main() {
  test('provider capability and gateway paths are explicit', () {
    expect(Deepseek.supported(own), isTrue);
    expect(Deepseek.supported(own.copyWith(model: 'deepseek-chat')), isFalse);
    expect(
      Deepseek.endpoint(own, '/v1/tools/ocr').toString(),
      'https://api.deepseek.com/v1/tools/ocr',
    );
    final gateway = own.copyWith(
      llmUrl: 'https://gateway.example/prefix/v1/chat/completions',
    );
    expect(Deepseek.supported(gateway), isFalse);
    expect(
      Deepseek.supported(gateway.copyWith(options: {'deepseekApps': true})),
      isTrue,
    );
    expect(
      Deepseek.endpoint(gateway, '/v1/tools/asr').path,
      '/prefix/v1/tools/asr',
    );
  });
  test('signed context is replayed only to its owning endpoint', () {
    final endpoint = Deepseek.endpoint(own).toString();
    final saved = {
      'provider': 'deepseek',
      'endpoint': endpoint,
      'files': [
        {'id': 'file_1', 'name': 'a.txt'},
      ],
      'server_tool_calls': [
        {'signature': 'opaque'},
      ],
    };
    final body = Deepseek.body(own, 'system', [
      {'role': 'user', 'content': 'old', 'deepseek': saved},
      {'role': 'assistant', 'content': 'answer', 'deepseek': saved},
    ], 'next');
    expect(body['messages'][1]['content'][0]['file_id'], 'file_1');
    expect(body['messages'][2]['server_tool_calls'], [
      {'signature': 'opaque'},
    ]);
    final other = own.copyWith(
      llmUrl: 'https://other.example/v1/chat/completions',
      options: {'deepseekApps': true},
    );
    final isolated = Deepseek.body(other, '', [
      {'role': 'user', 'content': 'old', 'deepseek': saved},
    ], 'next');
    expect(isolated['messages'][1]['content'], 'old');
    expect(
      () => Deepseek.body(
        other,
        '',
        [],
        'next',
        files: [
          {'id': 'file_1', 'endpoint': endpoint},
        ],
      ),
      throwsA(isA<ApiFailure>()),
    );
  });
  test(
    'stream handles fragmented UTF8, reasoning, sources and length completion',
    () async {
      final frames = [
        {
          'choices': [
            {
              'delta': {'reasoning_content': '想一想'},
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {'content': '你好'},
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {
                'annotations': [
                  {
                    'url_citation': {
                      'url': 'https://example.com/a',
                      'title': '来源',
                    },
                  },
                ],
                'title': '对话标题',
              },
              'server_tool_event': {
                'step': 0,
                'call': {'index': 1},
              },
              'finish_reason': 'length',
            },
          ],
          'usage': {'total_tokens': 12},
        },
      ].map((d) => 'data: ${jsonEncode(d)}\r\n\r\n').join();
      final bytes = utf8.encode('${frames}data: [DONE]\r\n\r\n');
      final reader = DeepseekReply(Deepseek.endpoint(own).toString());
      final result = await reader
          .read(
            http.StreamedResponse(
              Stream.fromIterable(bytes.map((b) => [b])),
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
            () {},
          )
          .toList();
      expect(
        result.where((e) => e.type == 'text').map((e) => e.text).join(),
        '你好',
      );
      expect(reader.reasoning, '想一想');
      expect(reader.metadata!['truncated'], isTrue);
      expect(Deepseek.sources(reader.metadata).single['title'], '来源');
      expect(result.last.completion!.usage['total_tokens'], 12);
    },
  );
  test(
    'missing terminal event and refusal never become completed replies',
    () async {
      for (final finish in ['stop', 'content_filter']) {
        final bytes = utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': 'partial'},
                'finish_reason': finish,
              },
            ],
          })}\n\n',
        );
        final reader = DeepseekReply('test');
        await expectLater(
          reader
              .read(
                http.StreamedResponse(
                  Stream.value(bytes),
                  200,
                  headers: {'content-type': 'text/event-stream'},
                ),
                () {},
              )
              .toList(),
          throwsA(isA<ApiFailure>()),
        );
      }
    },
  );
  test('own uploads never send site cookies; official account mismatch prevents upload', () async {
    final calls = <http.Request>[];
    final personal = DeepseekClient(
      clientFactory: () => MockClient((req) async {
        calls.add(req);
        expect(req.headers['cookie'], isNull);
        expect(req.headers['authorization'], 'Bearer test-key');
        return http.Response('{"id":"file_1"}', 201);
      }),
    );
    expect(
      (await personal.upload(
        own,
        '/files',
        [1, 2],
        'a.txt',
        'text/plain',
        cookie: 'private-cookie',
      ))['id'],
      'file_1',
    );
    var uploads = 0;
    final official = DeepseekClient(
      clientFactory: () => MockClient((req) async {
        if (req.method == 'POST') uploads++;
        return http.Response(
          jsonEncode({
            'me': {'site_user_id': 'other', 'account_id': 'a'},
            'models': [],
          }),
          200,
        );
      }),
    );
    final s = own.copyWith(
      siteUrl: 'https://site.example',
      llmUrl: 'https://site.example/official-api/v1/chat/completions',
    );
    await expectLater(
      official.upload(
        s,
        '/files',
        [1],
        'a.txt',
        'text/plain',
        cookie: 'cookie',
        accountId: 'mine',
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(uploads, 0);
  });
  test('WAV header describes bounded 16kHz mono PCM', () {
    final wav = RoomVoiceInput.wav(Uint8List(32000));
    final header = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), 32000);
    expect(wav.length, 32044);
  });
  test('conversation metadata survives local sync representation', () {
    final turn = ChatTurn(
      id: 'a',
      user: 'q',
      assistant: 'a',
      createdAt: DateTime(2026),
      deepseek: {
        'user': {'provider': 'deepseek', 'files': []},
        'assistant': {'provider': 'deepseek', 'title': '标题'},
      },
    );
    expect(ChatTurn.fromJson(turn.toJson()).synced().deepseek, turn.deepseek);
  });
}
