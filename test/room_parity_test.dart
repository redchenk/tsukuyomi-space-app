import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_archive.dart';
import 'package:tsukuyomi_space_app/core/room_protocol.dart';
import 'package:tsukuyomi_space_app/core/room_tools.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/live2d/room_animation.dart';

import 'support/fakes.dart';

import 'package:tsukuyomi_space_app/core/room_reply.dart';

void main() {
  test('reply bubbles preserve URLs, decimals, quotations and code', () {
    expect(splitRoomReply('「要一起吗？」（眨眼）当然呀！👩‍🚀'), [
      '「要一起吗？」',
      '（眨眼）当然呀！',
      '👩‍🚀',
    ]);
    expect(
      splitRoomReply(
        'Dr. Lee paid 3.14 today. Look at https://example.com/a?x=1.2 next!',
      ),
      ['Dr. Lee paid 3.14 today.', 'Look at https://example.com/a?x=1.2 next!'],
    );
    expect(splitRoomReply('Use `a.b()` here. Then run it!'), [
      'Use `a.b()` here.',
      'Then run it!',
    ]);
  });

  for (final entry in {
    'openai': 'data: {"choices":[{"delta":{"content":"你好"},"finish_reason":null}]}\r\n\r\ndata: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
    'responses': 'data: {"type":"response.output_text.delta","delta":"你好"}\n\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n',
    'anthropic': 'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n',
    'ollama': '{"message":{"content":"你好"},"done":false}\n{"message":{"content":""},"done":true}\n',
    'proxy': 'event: delta\ndata: {"text":"你好"}\n\nevent: done\ndata: {"reply":"你好"}\n\n',
  }.entries) {
    test(
      '${entry.key} stream handles fragmented UTF-8 and completion',
      () async {
        expect(
          await decodeRoomStream(
            Stream.fromIterable(utf8.encode(entry.value).map((b) => [b])),
            entry.key,
          ).join(),
          '你好',
        );
      },
    );
    test('${entry.key} partial EOF cannot become a completed turn', () async {
      final first = entry.key == 'ollama'
          ? '${entry.value.split('\n').first}\n'
          : '${entry.value.replaceAll('\r', '').split('\n\n').first}\n\n';
      await expectLater(
        decodeRoomStream(Stream.value(utf8.encode(first)), entry.key).join(),
        throwsA(isA<ApiFailure>()),
      );
    });
  }
  test('compatible stream fallback only retries explicit stream unsupported errors', () async {
    var calls = 0;
    final llm = LlmClient(
      clientFactory: () => MockClient((req) async {
        final body = jsonDecode(req.body);
        calls++;
        if (calls == 1) {
          expect(body['stream'], true);
          return http.Response('{"error":"stream is not supported"}', 400);
        }
        expect(body['stream'], false);
        return http.Response(
          '{"choices":[{"message":{"content":"works"},"finish_reason":"stop"}]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    expect(
      await llm
          .reply(const RoomSettings(demo: false, model: 'model'), [], 'hi')
          .join(),
      'works',
    );
    expect(calls, 2);
  });
  test('Responses and Anthropic reject incomplete output', () async {
    for (final payload in [
      '{"type":"response.incomplete"}',
      '{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}',
    ]) {
      await expectLater(
        decodeRoomStream(
          Stream.value(utf8.encode('data: $payload\n\n')),
          'responses',
        ).join(),
        throwsA(isA<ApiFailure>()),
      );
    }
    expect(
      () => validateCompletion({'stop_reason': 'tool_use'}),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('all provider request shapes contain images and correct separate credentials', () {
    const image = {
      'dataUrl': 'data:image/png;base64,AAAA',
      'type': 'image/png',
    };
    for (final url in [
      'https://api.openai.com/v1/responses',
      'https://api.anthropic.com/v1/messages',
      'http://localhost:11434/api/chat',
      'https://example.com/v1/chat/completions',
    ]) {
      final s = RoomSettings(
        demo: false,
        llmUrl: url,
        model: 'test',
        apiKey: 'llm-only',
        ttsKey: 'tts-never',
      );
      final body = roomChatBody(s, 'system', [], 'hello', image: image);
      expect(jsonEncode(body), contains('AAAA'));
      expect(jsonEncode(body), isNot(contains('tts-never')));
      final headers = roomChatHeaders(s, Uri.parse(url));
      expect(
        headers.values,
        contains(url.contains('anthropic') ? 'llm-only' : 'Bearer llm-only'),
      );
      expect(headers.keys, isNot(contains('Cookie')));
    }
  });
  test(
    'MCP sends JSON-RPC auth metadata, respects whitelist and isolates cookies',
    () async {
      final requests = <http.Request>[];
      final tools = RoomTools(
        clientFactory: () => MockClient((req) async {
          requests.add(req);
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': jsonDecode(req.body)['id'],
              'result': {
                'content': [
                  {'type': 'text', 'text': 'result'},
                ],
              },
            }),
            200,
          );
        }),
      );
      var s = const RoomSettings(
        mcpKey: 'tool-key',
        options: {
          'mcpEnabled': true,
          'mcpEndpoint': 'https://tools.example/rpc',
          'mcpAllowlist': 'web_search',
        },
      );
      expect(
        await tools.tool(s, 'understand_image', {}, cookie: 'session=private'),
        '',
      );
      expect(requests, isEmpty);
      expect(
        await tools.tool(s, 'web_search', {
          'query': 'test',
        }, cookie: 'session=private'),
        'result',
      );
      expect(requests.last.headers.keys, isNot(contains('cookie')));
      expect(requests.last.headers['authorization'], 'Bearer tool-key');
      expect(
        jsonDecode(requests.last.body)['params']['meta']['auth']['api_key'],
        'tool-key',
      );
      s = s.copyWith(
        options: {...s.options, 'mcpEndpoint': '/api/mcp/token-plan'},
      );
      await tools.tool(s, 'web_search', {}, cookie: 'session=private');
      expect(requests.last.headers['cookie'], 'session=private');
      expect(requests.last.headers.keys, isNot(contains('authorization')));
    },
  );
  test(
    'offline image upload retries with same id without losing completed reply',
    () async {
      final store = MemoryStorage()
        ..value = const RoomSettings(demo: false, model: 'test');
      final site = ArchiveSite();
      final c = RoomController(
        storage: store,
        chat: FakeChat(),
        site: site,
        voice: SilentVoice(),
      );
      await c.initialize();
      await c.login('alice', 'pass');
      addTearDown(c.dispose);
      site.offline = true;
      await c.attach({
        'name': 'one.png',
        'dataUrl': 'data:image/png;base64,AA==',
      });
      await c.send('');
      expect(c.turns.single.assistant, '这是完整回复。');
      expect(c.turns.single.pending, true);
      expect(c.turns.single.image!['dataUrl'], isNotNull);
      final id = c.turns.single.id;
      site.offline = false;
      await c.sync();
      expect(c.turns.single.id, id);
      expect(c.turns.single.pending, false);
      expect(c.turns.single.image!['id'], 'image-$id');
      expect(site.imageIds.every((v) => v == id), true);
    },
  );
  test('failed diary sync keeps recording and retry uses the saved diary exactly once', () async {
    final store = MemoryStorage()
      ..value = const RoomSettings(demo: false, model: 'test');
    final site = ArchiveSite();
    var generations = 0;
    final c = RoomController(
      storage: store,
      chat: FakeChat(),
      site: site,
      voice: SilentVoice(),
      diaryClientFactory: () {
        generations++;
        return FakeChat()..answer = '今晚一起聊了月亮，也聊了白天发生的小事。我把这些温柔的片刻认真记下。';
      },
    );
    await c.initialize();
    await c.login('alice', 'pass');
    addTearDown(c.dispose);
    await c.send('今天很好');
    site.offline = true;
    await expectLater(c.finishDiary(), throwsA(isA<ApiFailure>()));
    expect(c.recording, isNotEmpty);
    expect(c.pendingDiary, isNotNull);
    expect(c.workspace.archive.entries.length, 1);
    final id = c.pendingDiary!['diaryId'];
    site.offline = false;
    await c.finishDiary();
    expect(c.recording, isEmpty);
    expect(c.turns, isEmpty);
    expect(c.workspace.archive.entries.single['diaryId'], id);
    expect(generations, 1);
    expect(site.diaries.length, 1);
  });
  test(
    'archive preserves unknown fields, tombstones and concurrent persona edits',
    () async {
      final site = ArchiveSite();
      final store = MemoryStorage();
      RoomArchive archive(String scope) => RoomArchive(
        storage: store,
        site: site,
        siteUrl: () => 'https://example.com',
        scope: () => scope,
        owner: () => 'alice',
        online: () => true,
      );
      final a = archive('a'), b = archive('b');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.load();
      await b.load();
      await a.importText(
        jsonEncode({
          ...defaultArchive(),
          'unknown': 'preserved',
          'data': {
            ...defaultArchive()['data'],
            'other': {'custom': 7},
            'diary': [
              {
                'date': '2026/9/1',
                'time': '12:00:00',
                'content': 'legacy note',
              },
            ],
          },
        }),
      );
      final id = a.entries.single['diaryId'];
      expect(a.exportText(), contains('preserved'));
      await a.sync();
      expect(a.status, '已与网站同步');
      await b.sync();
      expect(b.entries.single['diaryId'], id);
      await a.savePersona({'name': '第一台'});
      await b.savePersona({'name': '第二台'});
      await a.sync();
      await b.sync();
      expect(b.prompts.length, 2);
      expect(b.personaData['name'], '第二台');
      await b.delete('$id');
      await b.sync();
      await a.sync();
      expect(a.entries, isEmpty);
      expect(site.tombstones, contains(id));
    },
  );
  test('animation queue drains and clears eye overrides after expressions', () {
    final a = RoomAnimation()..ready = true;
    addTearDown(a.dispose);
    a.enqueue({
      'expression': 'closed_smile',
      'motion': 'nod',
      'durationMs': 1000,
    });
    a.advance(.1);
    expect(a.parameters['ParamEyeLOpen'], 0);
    expect(a.current, isNotNull);
    a.advance(1);
    expect(a.parameters, isEmpty);
    expect(a.expression, 'neutral');
    expect(a.scale, 1);
  });
  test('machine controls removed while conversational parentheses survive', () {
    expect(
      cleanRoomReply('<think>hidden</think>你好（挥手）\n\n今天好吗？'),
      '你好（挥手）\n\n今天好吗？',
    );
    expect(cleanRoomReply('<think>unfinished'), '');
  });
}

class ArchiveSite extends FakeSite implements SiteDataService {
  final diaries = <String, Map<String, dynamic>>{};
  final tombstones = <String>{};
  final imageIds = <String>[];
  Map<String, dynamic>? metadata;
  int revision = 0;
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (path == '/api/room/chat/images') {
      imageIds.add('${body!['turnId']}');
      if (offline) throw const ApiFailure('offline');
      return {
        'data': {
          'id': 'image-${body['turnId']}',
          'url': '/image.png',
          'name': body['name'],
        },
      };
    }
    if (offline) throw const ApiFailure('offline');
    if (path == '/api/room/chat' && method == 'DELETE') {
      data.clear();
      return {'data': {}};
    }
    if (path.startsWith('/api/room/diary/metadata')) {
      if (method == 'PUT') {
        if (body!['expectedRevision'] != revision) {
          throw const ApiFailure('conflict', status: 409);
        }
        metadata = jsonMap(jsonDecode(jsonEncode(body['metadata'])));
        return {
          'data': {'revision': ++revision},
        };
      }
      return {
        'data': {'userId': userId, 'metadata': metadata, 'revision': revision},
      };
    }
    if (path == '/api/room/diary/sync') {
      for (final id in body!['deletedIds'] as List) {
        diaries.remove(id);
        tombstones.add('$id');
      }
      for (final entry in jsonRows(body['entries'])) {
        if (!tombstones.contains(entry['diaryId'])) {
          diaries['${entry['diaryId']}'] = entry;
        }
      }
      return {'data': {}};
    }
    if (path == '/api/room/diary') {
      return {
        'data': {
          'userId': userId,
          'entries': [
            for (final e in diaries.entries)
              {'diaryId': e.key, 'entry': e.value, 'deleted': false},
            for (final id in tombstones) {'diaryId': id, 'deleted': true},
          ],
          'nextCursor': null,
        },
      };
    }
    return {'data': {}};
  }
}
