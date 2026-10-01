import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_bridge.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_limits.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_progress.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_provider.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_tools.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_types.dart';
import 'package:tsukuyomi_space_app/core/agent/structured_agent_runtime.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';

import 'support/svg_fixture.dart';

void main() {
  late Directory root;
  late ToolGateway gateway;
  late List<AgentEvent> events;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-svg-');
    events = [];
    gateway = ToolGateway(
      workspace: root.path,
      approve: (_) async => false,
      emit: events.add,
      commandRunner: SandboxCommandRunner('missing'),
    )..begin();
  });
  tearDown(() async {
    gateway.cancel();
    await root.delete(recursive: true);
  });
  AgentSession session() =>
      AgentSession(id: 'svg', owner: 'guest', workspace: root.path);
  http.Response completion(String action, {String finish = 'stop'}) =>
      http.Response(
        jsonEncode({
          'choices': [
            {
              'index': 0,
              'message': {'content': action},
              'finish_reason': finish,
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
  Map<String, dynamic> writeAction(String svg) => {
    'type': 'tool',
    'commentary': '我会保存鹈鹕骑车 SVG。',
    'name': 'fs_write',
    'arguments': {'path': 'pelican.svg', 'content': svg},
  };
  for (final protocol in ['openai', 'responses', 'ollama', 'anthropic']) {
    test(
      'structured SVG roundtrip retains the $protocol request contract',
      () async {
        var requests = 0;
        final endpoint = switch (protocol) {
          'responses' => 'https://fixture.test/v1/responses',
          'ollama' => 'http://localhost:11434/api/chat',
          'anthropic' => 'https://fixture.test/v1/messages',
          _ => 'https://fixture.test/v1/chat/completions',
        };
        final client = LlmClient(
          clientFactory: () => MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            switch (protocol) {
              case 'responses':
                expect(body['text']['format'], {'type': 'json_object'});
              case 'ollama':
                expect(body['format'], 'json');
              case 'anthropic':
                expect(body['system'], contains('JSON-escaped'));
              default:
                expect(body['response_format'], {'type': 'json_object'});
            }
            final action = ++requests == 1
                ? jsonEncode(
                    writeAction(
                      '<svg xmlns="http://www.w3.org/2000/svg">\n<title>鹈鹕</title></svg>',
                    ),
                  )
                : '{"type":"final","text":"完成"}';
            final payload = switch (protocol) {
              'responses' => {'status': 'completed', 'output_text': action},
              'ollama' => {
                'done': true,
                'message': {'content': action},
              },
              'anthropic' => {
                'stop_reason': 'end_turn',
                'content': [
                  {'type': 'text', 'text': action},
                ],
              },
              _ => {
                'choices': [
                  {
                    'message': {'content': action},
                    'finish_reason': 'stop',
                  },
                ],
              },
            };
            return http.Response(
              jsonEncode(payload),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        final runtime = StructuredAgentRuntime(gateway, chat: client);
        await runtime.send(
          session(),
          '保存 SVG',
          RoomSettings(model: 'fixture', llmUrl: endpoint),
          events.add,
        );
        expect(requests, 2);
        expect(
          await File('${root.path}/pelican.svg').readAsString(),
          contains('<title>鹈鹕</title>'),
        );
        await runtime.dispose();
      },
    );
  }
  test(
    'empty JSON provider output gets one repair before any file write',
    () async {
      var requests = 0;
      final client = LlmClient(
        clientFactory: () => MockClient((request) async {
          requests++;
          if (requests == 1) return completion('');
          if (requests == 2) {
            expect(
              (jsonDecode(request.body)['messages'] as List).last['content'],
              contains('No JSON action was returned'),
            );
            expect(gateway.calls, 0);
            return completion(jsonEncode(writeAction('<svg/>')));
          }
          return completion('{"type":"final","text":"完成"}');
        }),
      );
      final runtime = StructuredAgentRuntime(gateway, chat: client);
      await runtime.send(
        session(),
        'SVG',
        const RoomSettings(model: 'fixture'),
        events.add,
      );
      expect(requests, 3);
      expect(gateway.calls, 1);
      await runtime.dispose();
    },
  );
  test('JSON mode repairs unescaped SVG using the actual error then writes a large artifact once', () async {
    final svg = pelicanSvgFixture();
    const malformed =
        '{"type":"tool","name":"fs_write","arguments":{"path":"pelican.svg","content":"<svg xmlns="http://www.w3.org/2000/svg">"}}';
    var requests = 0;
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['response_format'], {'type': 'json_object'});
        final messages = body['messages'] as List;
        expect(messages.first['content'], contains('JSON-escaped'));
        final task = messages.last['content'] as String;
        requests++;
        if (requests == 1) return completion(malformed);
        if (requests == 2) {
          expect(task, contains('Validation error:'));
          expect(task, contains(jsonEncode(malformed)));
          expect(await File('${root.path}/pelican.svg').exists(), false);
          expect(gateway.calls, 0);
          return completion(jsonEncode(writeAction(svg)));
        }
        expect(task.length, lessThan(26000));
        expect(task, contains('written'));
        return completion(
          jsonEncode({'type': 'final', 'text': '已保存 pelican.svg。'}),
        );
      }),
    );
    final runtime = StructuredAgentRuntime(gateway, chat: client);
    await runtime.send(
      session(),
      '生成鹈鹕骑车 SVG',
      const RoomSettings(model: 'fixture'),
      events.add,
    );
    expect(requests, 3);
    expect(svg.length, greaterThan(65536));
    expect(await File('${root.path}/pelican.svg').readAsString(), svg);
    expect(gateway.calls, 1);
    expect(events.where((e) => e.type == 'info'), hasLength(1));
    await runtime.dispose();
  });
  test('truncated JSON never executes; a single shorter repaired action can complete', () async {
    var requests = 0;
    final svg =
        '<svg xmlns="http://www.w3.org/2000/svg"><title>鹈鹕</title></svg>';
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        final task =
            (jsonDecode(request.body)['messages'] as List).last['content']
                as String;
        requests++;
        if (requests == 1) {
          return completion(
            '{"type":"tool","name":"fs_write","arguments":{',
            finish: 'length',
          );
        }
        if (requests == 2) {
          expect(task, contains('truncated'));
          expect(gateway.calls, 0);
          return completion(jsonEncode(writeAction(svg)));
        }
        return completion('{"type":"final","text":"已保存"}');
      }),
    );
    final runtime = StructuredAgentRuntime(gateway, chat: client);
    await runtime.send(
      session(),
      '生成 SVG',
      const RoomSettings(model: 'fixture'),
      events.add,
    );
    expect(await File('${root.path}/pelican.svg').readAsString(), svg);
    expect(gateway.calls, 1);
    await runtime.dispose();
  });
  test('providers rejecting JSON mode retry once and keep strict validation on following requests', () async {
    var requests = 0;
    final client = LlmClient(
      clientFactory: () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        requests++;
        if (requests == 1) {
          expect(body['response_format'], isNotNull);
          return http.Response('response_format json_object unsupported', 400);
        }
        expect(body.containsKey('response_format'), false);
        return completion(
          requests == 2
              ? jsonEncode(writeAction('<svg/>'))
              : '{"type":"final","text":"完成"}',
        );
      }),
    );
    final runtime = StructuredAgentRuntime(gateway, chat: client);
    await runtime.send(
      session(),
      '保存 SVG',
      const RoomSettings(model: 'fixture'),
      events.add,
    );
    expect(requests, 3);
    expect(await File('${root.path}/pelican.svg').readAsString(), '<svg/>');
    await runtime.dispose();
  });
  for (final status in [401, 429, 500]) {
    test('JSON mode preserves HTTP $status without format retries', () async {
      var requests = 0;
      final client = LlmClient(
        clientFactory: () => MockClient((_) async {
          requests++;
          return http.Response('json format unavailable', status);
        }),
      )..jsonObject = true;
      await expectLater(
        client
            .reply(const RoomSettings(model: 'fixture'), [], 'JSON action')
            .join(),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', status)),
      );
      expect(requests, 1);
      expect(gateway.calls, 0);
    });
  }
  test('only a single complete fenced JSON action is accepted, including CRLF and uppercase JSON', () {
    final action = jsonEncode(writeAction('<svg a="quoted">\n</svg>'));
    expect(
      parseStructuredAction(
        '```JSON\r\n$action\r\n```',
        gateway,
      )['arguments']['content'],
      '<svg a="quoted">\n</svg>',
    );
    expect(
      () => parseStructuredAction('$action\n$action', gateway),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseStructuredAction('$action\nrun command', gateway),
      throwsA(isA<FormatException>()),
    );
  });
  test('UTF-8 file budget remains bounded and oversized writes preserve the existing artifact', () async {
    final file = File('${root.path}/pelican.svg');
    await file.writeAsString('original');
    await expectLater(
      gateway.call('fs_write', {
        'path': 'pelican.svg',
        'content': List.filled(agentMaxFileBytes ~/ 3 + 1, '鹈').join(),
      }),
      throwsA(isA<ApiFailure>()),
    );
    expect(await file.readAsString(), 'original');
    expect(events.where((e) => e.type == 'diff'), isEmpty);
  });
  test('SSE overhead above 2 MiB does not stop a bounded SVG tool response', () async {
    final arguments = jsonEncode(writeAction(pelicanSvgFixture())['arguments']);
    final packets = <String>[];
    for (var i = 0; i < arguments.length; i += 12) {
      packets.add(
        'data: ${jsonEncode({
          'id': 'chatcmpl-svg',
          'object': 'chat.completion.chunk',
          'created': 1,
          'model': 'fixture',
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'svg',
                    'type': 'function',
                    'function': {'name': 'fs_write', 'arguments': arguments.substring(i, i + 12 < arguments.length ? i + 12 : arguments.length)},
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        })}\n\n',
      );
    }
    packets.add(
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n',
    );
    final wire = packets.join();
    expect(utf8.encode(wire).length, greaterThan(2 * 1024 * 1024));
    final provider = AgentProviderBridge(
      const RoomSettings(model: 'fixture'),
      clientFactory: () => MockClient(
        (_) async => http.Response(
          wire,
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        ),
      ),
    );
    final bridge = AgentBridge(gateway, provider);
    await bridge.start();
    final client = http.Client();
    try {
      final response = await client.send(
        http.Request('POST', bridge.uri.resolve('/model/v1/chat/completions'))
          ..headers['Authorization'] = 'Bearer ${bridge.token}'
          ..body = jsonEncode({
            'stream': true,
            'messages': [
              {'role': 'user', 'content': 'SVG'},
            ],
          }),
      );
      final joined = StringBuffer();
      await for (final chunk in decodeAgentSse(response.stream)) {
        expect(chunk['error'], isNull);
        for (final choice in chunk['choices'] as List? ?? []) {
          for (final call in choice['delta']?['tool_calls'] as List? ?? []) {
            joined.write(call['function']['arguments']);
          }
        }
      }
      expect(joined.toString(), arguments);
      expect(provider.lastFailure, isNull);
    } finally {
      client.close();
      await bridge.dispose();
    }
  });
}
