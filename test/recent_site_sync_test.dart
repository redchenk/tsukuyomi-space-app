import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/model_catalog.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/model_runtime.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_context.dart';
import 'package:tsukuyomi_space_app/core/room_knowledge.dart';
import 'package:tsukuyomi_space_app/features/site/site_notice.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final model = fixture('model_runtime_web');
  for (final (index, item) in (model['cases'] as List).indexed) {
    test('independent website runtime fixture $index', () {
      final s = item['settings'];
      final runtime = ModelRuntime(
        RoomSettings(
          llmUrl: s['apiUrl'],
          model: s['model'],
          options: {'runtimeConfig': s['runtimeConfig']},
        ),
      );
      expect(
        runtime.apply(Map<String, dynamic>.from(item['payload'])),
        item['expected'],
      );
      expect(runtime.resolveCapabilities(), item['capabilities']);
    });
  }
  for (final item in model['plans'] as List) {
    final input = item['input'];
    test('catalog official host ${input['apiUrl']}', () {
      final settings = RoomSettings(
        llmUrl: input['apiUrl'],
        apiKey: input['apiKey'],
        options: {'aliyunWorkspaceId': input['workspaceId']},
      );
      if (item['error'] != null) {
        expect(() => catalogPlan(settings), throwsA(isA<ApiFailure>()));
        return;
      }
      final plan = catalogPlan(settings), expected = item['expected'];
      expect(plan.provider, expected['provider']);
      final url = Uri.parse(expected['url']);
      expect(plan.url.host, url.host);
      expect(plan.url.path, url.path);
      expect(plan.url.queryParameters, url.queryParameters);
      expect(plan.headers, expected['headers']);
    });
  }
  for (final item in model['catalogCases'] as List) {
    test('catalog filters actual text models ${item['provider']}', () {
      final normalized = normalizeCatalog(item['payload'], item['provider']);
      Map project(Map row) => {
        for (final key in [
          'id',
          'nativeId',
          'label',
          'contextLength',
          'capabilities',
        ])
          key: row[key],
      };
      expect(
        normalized.models.map(project).toList(),
        (item['expected']['models'] as List).cast<Map>().map(project).toList(),
      );
      expect(normalized.cursor, item['expected']['nextCursor']);
    });
  }
  test('untrusted catalogs cannot receive a credential', () async {
    var calls = 0;
    final catalog = ModelCatalog(
      client: MockClient((r) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(catalog.close);
    for (final url in [
      'https://api.deepseek.com.evil.test/chat/completions',
      'https://user:pass@api.deepseek.com/chat/completions',
      'https://api.deepseek.com/chat/completions?redirect=evil',
      'http://api.deepseek.com/chat/completions',
    ]) {
      await expectLater(
        catalog.load(RoomSettings(llmUrl: url, apiKey: 'secret')),
        throwsA(isA<ApiFailure>()),
      );
    }
    expect(calls, 0);
  });
  test('catalog refuses redirects and bounds response bytes', () async {
    for (final status in [302, 200]) {
      final catalog = ModelCatalog(
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          expect(request.url.host, 'api.deepseek.com');
          expect(request.headers['Authorization'], 'Bearer fixture-key');
          return http.Response(
            status == 200 ? ' ' * (2 * 1024 * 1024 + 1) : '',
            status,
            headers: {'location': 'https://evil.test'},
          );
        }),
      );
      await expectLater(
        catalog.load(
          const RoomSettings(
            llmUrl: 'https://api.deepseek.com/chat/completions',
            apiKey: 'fixture-key',
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      catalog.close();
    }
  });
  test('runtime rejects unlisted mappings and invalid values', () {
    for (final layer in [
      {
        'mappings': {'temperature': 'api_key'},
      },
      {
        'parameters': {'maxOutputTokens': 15},
      },
      {
        'parameters': {'temperature': double.nan},
      },
      {
        'parameters': {'reasoningEnabled': 'true'},
      },
    ]) {
      expect(
        () => normalizeModelRuntime({
          'models': {'provider#model': layer},
        }),
        throwsA(isA<ApiFailure>()),
      );
    }
  });
  for (final (url, field) in [
    ('https://api.deepseek.com/chat/completions', 'max_tokens'),
    ('https://api.openai.com/v1/responses', 'max_output_tokens'),
    ('https://api.anthropic.com/v1/messages', 'max_tokens'),
    ('http://localhost:11434/api/chat', 'options.num_predict'),
  ]) {
    test('native transport applies runtime configuration $url', () async {
      var requests = 0;
      final client =
          LlmClient(
              clientFactory: () => MockClient((request) async {
                requests++;
                final body = jsonDecode(request.body) as Map;
                final parts = field.split('.');
                expect(
                  parts.length == 1 ? body[field] : body[parts[0]][parts[1]],
                  128,
                );
                expect(body['stream'], isFalse);
                expect(body['tools'], isNull);
                return http.Response(
                  jsonEncode({'reply': '配置生效'}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            )
            ..tools = [
              {
                'name': 'web_search',
                'description': 'fixture',
                'parameters': {'type': 'object'},
              },
            ]
            ..executeTool = (_) async =>
                throw StateError('disabled tools must not run');
      addTearDown(client.cancel);
      final key = '$url#fixture-model';
      final settings = RoomSettings(
        llmUrl: url,
        model: 'fixture-model',
        options: {
          'runtimeConfig': {
            'models': {
              key: {
                'parameters': {'maxOutputTokens': 128},
                'capabilities': {'streaming': false, 'tools': false},
              },
            },
          },
        },
      );
      expect(await client.reply(settings, [], '测试配置').join(), '配置生效');
      expect(requests, 1);
    });
  }
  final knowledge = fixture('room_knowledge_web');
  for (final item in knowledge['cases'] as List) {
    test('website knowledge ranking ${item['message']}', () {
      final history = [
        for (final message in item['history'] as List)
          ChatTurn(
            id: 'prior',
            createdAt: DateTime(2026, 10, 1),
            user: message['content'],
            assistant: '模型编造的旧结论',
          ),
      ];
      final selected = selectRoomKnowledge(
        item['message'],
        const RoomSettings(),
        history: history,
      );
      expect(selected.map((row) => row['id']).toList(), item['ids']);
      expect(
        shouldRetrieveRoomPersona(
          roomKnowledgeQuery(item['message'], history),
          selected,
        ),
        item['persona'],
      );
    });
  }
  for (final (index, item) in (knowledge['migrations'] as List).indexed) {
    test(
      'knowledge migration preserves reduced libraries and custom facts $index',
      () {
        final actual = roomKnowledgeEntries(
          RoomSettings(options: {'knowledge': item['entries']}),
        );
        Map project(Map row) => {
          'id': row['id'],
          'title': row['title'],
          'content': row['content'],
          'tags': row['tags'],
          'enabled': row['enabled'] != false,
          'edition': row['edition'] ?? '',
          'references': row['references'] ?? [],
          'spoiler': row['spoiler'] == true,
        };
        expect(
          actual.map(project).toList(),
          (item['expected'] as List).cast<Map>().map(project).toList(),
        );
      },
    );
  }
  test('30 retrieved memories share the source budget instead of starving later facts', () {
    final pack = packRoomContext({
      'memories': [
        for (var i = 0; i < 30; i++)
          {'id': 'memory-$i', 'content': '事实$i ${'x' * 1000}'},
      ],
    });
    expect(pack.trace.length, 30);
    expect(pack.trace.every((item) => item.includedChars == 100), isTrue);
    expect(
      pack.trace.fold<int>(0, (sum, item) => sum + item.includedChars),
      3000,
    );
    expect(pack.usedChars, lessThanOrEqualTo(8000));
    expect(memoryRetrievalLimit(const RoomSettings()), 12);
    expect(
      memoryRetrievalLimit(
        const RoomSettings(options: {'memoryRetrievalLimit': 99}),
      ),
      30,
    );
  });
  test(
    'notice links stay native internally and reject active or credential URLs',
    () {
      for (final value in [
        'javascript:alert(1)',
        'data:text/html,hello',
        '//evil.test',
        'https://u:p@evil.test',
        '/\\evil.test',
        '/path\nnext',
      ]) {
        expect(safeNoticeLink(value, 'https://yachiyo.hk'), isNull);
      }
      expect(
        safeNoticeLink(
          '/articles/42?q=story#comment-1',
          'https://yachiyo.hk',
        )?.internal,
        isTrue,
      );
      expect(
        safeNoticeLink(
          'https://www.yachiyo.hk/wiki',
          'https://yachiyo.hk',
        )?.internal,
        isTrue,
      );
      expect(
        safeNoticeLink(
          'https://external.test/page',
          'https://yachiyo.hk',
        )?.internal,
        isFalse,
      );
      expect(
        announcementContent({
          'siteAnnouncement': '欢迎访问月读空间',
          'visitPopupContent': '**新公告**',
        }),
        '**新公告**',
      );
      expect(noticeSummary('## 标题\n\n[正文](/stage)'), '标题');
    },
  );
}
