import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_bridge.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_provider.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_tools.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/model_protocol.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_protocol.dart';
import 'package:tsukuyomi_space_app/core/room_tools.dart';

String sse(Map value, [String event = 'message']) =>
    'event: $event\r\ndata: ${jsonEncode(value)}\r\n\r\n';
Stream<List<int>> fragmented(String value) =>
    Stream.fromIterable(utf8.encode(value).map((b) => [b]));
Map<String, dynamic> callJson(String id, String name, Map args) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(args)},
};
const privateState = 'OPAQUE_PROVIDER_STATE_DO_NOT_DISPLAY';
Map<String, dynamic> fixture(
  String protocol, {
  String id = 'read1',
  String name = 'web_search',
  String text = '我会检查。',
}) {
  final args = {'query': '月读空间'};
  return switch (protocol) {
    'responses' => {
      'status': 'completed',
      'model': 'fixture',
      'output': [
        {
          'type': 'reasoning',
          'id': 'reason1',
          'encrypted_content': privateState,
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text},
          ],
        },
        {
          'type': 'function_call',
          'call_id': id,
          'name': name,
          'arguments': jsonEncode(args),
        },
      ],
      'usage': {'input_tokens': 5, 'output_tokens': 3},
    },
    'anthropic' => {
      'model': 'fixture',
      'content': [
        {
          'type': 'thinking',
          'thinking': 'private thought',
          'signature': privateState,
        },
        {'type': 'text', 'text': text},
        {'type': 'tool_use', 'id': id, 'name': name, 'input': args},
      ],
      'stop_reason': 'tool_use',
      'usage': {'input_tokens': 5, 'output_tokens': 3},
    },
    'ollama' => {
      'model': 'fixture',
      'message': {
        'role': 'assistant',
        'content': text,
        'tool_calls': [
          {
            'function': {'name': name, 'arguments': args},
          },
        ],
      },
      'done': true,
      'prompt_eval_count': 5,
      'eval_count': 3,
    },
    _ => {
      'model': 'fixture',
      'choices': [
        {
          'index': 0,
          'message': {
            'role': 'assistant',
            'content': text,
            'reasoning_content': privateState,
            'tool_calls': [callJson(id, name, args)],
          },
          'finish_reason': 'tool_calls',
        },
      ],
      'usage': {'prompt_tokens': 5, 'completion_tokens': 3},
    },
  };
}

String wireFixture(String protocol) {
  final value = fixture(protocol);
  if (protocol == 'ollama') {
    return '${jsonEncode({
      ...value,
      'message': {'content': '我会', 'thinking': privateState},
      'done': false,
    })}\n${jsonEncode({
      ...value,
      'message': {...value['message'], 'content': '检查。'},
    })}\n';
  }
  if (protocol == 'responses') {
    return sse({'type': 'response.output_text.delta', 'delta': '我会'}) +
        sse({'type': 'response.output_text.delta', 'delta': '检查。'}) +
        sse({'type': 'response.completed', 'response': value});
  }
  if (protocol == 'anthropic') {
    return [
      sse({
        'type': 'message_start',
        'message': {
          'model': 'fixture',
          'usage': {'input_tokens': 5},
        },
      }),
      sse({
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking', 'thinking': '', 'signature': ''},
      }),
      sse({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'private thought'},
      }),
      sse({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'signature_delta', 'signature': privateState},
      }),
      sse({
        'type': 'content_block_start',
        'index': 1,
        'content_block': {'type': 'text', 'text': ''},
      }),
      sse({
        'type': 'content_block_delta',
        'index': 1,
        'delta': {'type': 'text_delta', 'text': '我会检查。'},
      }),
      sse({
        'type': 'content_block_start',
        'index': 2,
        'content_block': {
          'type': 'tool_use',
          'id': 'read1',
          'name': 'web_search',
          'input': {},
        },
      }),
      sse({
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'input_json_delta', 'partial_json': '{"query":"月'},
      }),
      sse({
        'type': 'content_block_delta',
        'index': 2,
        'delta': {'type': 'input_json_delta', 'partial_json': '读空间"}'},
      }),
      sse({
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
        'usage': {'output_tokens': 3},
      }),
      sse({'type': 'message_stop'}),
    ].join();
  }
  return [
    sse({
      'choices': [
        {
          'index': 0,
          'delta': {'content': '我会', 'reasoning_content': privateState},
          'finish_reason': null,
        },
      ],
    }),
    sse({
      'choices': [
        {
          'index': 0,
          'delta': {
            'content': '检查。',
            'tool_calls': [
              {
                'index': 0,
                'id': 'read1',
                'function': {'name': 'web_search', 'arguments': '{"query":"月'},
              },
            ],
          },
          'finish_reason': null,
        },
      ],
    }),
    sse({
      'choices': [
        {
          'index': 0,
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': '读空间"}'},
              },
            ],
          },
          'finish_reason': 'tool_calls',
        },
      ],
    }),
    sse({
      'choices': [],
      'usage': {'prompt_tokens': 5, 'completion_tokens': 3},
    }),
    'data: [DONE]\r\n\r\n',
  ].join();
}

void main() {
  test(
    'legacy reply envelopes remain compatible while empty replies still fail',
    () {
      for (final protocol in ['openai', 'responses', 'anthropic', 'ollama']) {
        expect(ModelCompletion.json({'reply': '兼容回复'}, protocol).reply, '兼容回复');
        expect(
          () => ModelCompletion.json({}, protocol),
          throwsA(isA<ModelIncompleteFailure>()),
        );
      }
    },
  );
  for (final protocol in ['openai', 'responses', 'anthropic', 'ollama']) {
    test(
      '$protocol fragmented tools, UTF-8, usage and private continuation',
      () async {
        final events = await decodeModelStream(
          fragmented(wireFixture(protocol)),
          protocol,
          allowTools: true,
        ).toList();
        final result = events.last.completion!;
        expect(
          events.where((e) => e.type == 'text').map((e) => e.text).join(),
          '我会检查。',
        );
        expect(result.calls, hasLength(1));
        expect(jsonDecode(result.calls.single.arguments), {'query': '月读空间'});
        expect(result.usage.values, contains(5));
        expect(result.usage.values, contains(3));
        expect(events.map((e) => e.text).join(), isNot(contains(privateState)));
        final payload = protocol == 'responses'
            ? {'input': <dynamic>[]}
            : {'messages': <dynamic>[]};
        final body = modelWithTools(payload, protocol, roomReadTools, [
          {
            'continuation': result.continuation,
            'results': [
              {
                'id': result.calls.single.id,
                'name': 'web_search',
                'content': 'failed reference',
                'isError': true,
              },
            ],
          },
        ]);
        if (protocol == 'responses') expect(body['store'], false);
        if (protocol != 'ollama') {
          expect(jsonEncode(body), contains(privateState));
        }
        if (protocol == 'anthropic') {
          expect(body['messages'].last['content'].single['is_error'], true);
        }
        if (protocol == 'ollama') {
          expect(body['messages'].last['tool_name'], 'web_search');
        }
      },
    );
    test('$protocol cannot execute unpaired results', () {
      final result = ModelCompletion.json(
        fixture(protocol),
        protocol,
        allowTools: true,
      );
      expect(
        () => modelWithTools(
          protocol == 'responses' ? {'input': []} : {'messages': []},
          protocol,
          [],
          [
            {
              'continuation': result.continuation,
              'results': [
                {
                  'id': 'wrong',
                  'name': 'web_search',
                  'content': 'ok',
                  'isError': false,
                },
              ],
            },
          ],
        ),
        throwsA(isA<ApiFailure>()),
      );
    });
    test(
      '$protocol loopback bridge delivers text before completion and preserves native tool continuation',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        var requests = 0;
        final seen = <Map>[];
        final finished = Completer<void>();
        server.listen((req) async {
          try {
            final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
            seen.add(body);
            requests++;
            if (requests == 1) {
              expect(body['stream'], true);
              req.response.headers.contentType = ContentType(
                'text',
                protocol == 'ollama' ? 'plain' : 'event-stream',
                charset: 'utf-8',
              );
              req.response.bufferOutput = false;
              final wire = wireFixture(protocol);
              final delimiter = protocol == 'ollama' ? '\n' : '\r\n\r\n';
              final boundary =
                  wire.indexOf(delimiter, wire.indexOf('我会')) +
                  delimiter.length;
              req.response.write(wire.substring(0, boundary));
              await req.response.flush();
              await release.future;
              req.response.write(wire.substring(boundary));
            } else {
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(switch (protocol) {
                  'responses' => {'status': 'completed', 'output_text': '完成。'},
                  'anthropic' => {
                    'content': [
                      {'type': 'text', 'text': '完成。'},
                    ],
                    'stop_reason': 'end_turn',
                  },
                  'ollama' => {
                    'message': {'content': '完成。'},
                    'done': true,
                  },
                  _ => {
                    'choices': [
                      {
                        'message': {'content': '完成。'},
                        'finish_reason': 'stop',
                      },
                    ],
                  },
                }),
              );
            }
            await req.response.close();
          } catch (error, stack) {
            if (!finished.isCompleted) finished.completeError(error, stack);
          }
        });
        final path = {
          'openai': '/chat/completions',
          'responses': '/responses',
          'anthropic': '/messages',
          'ollama': '/api/chat',
        }[protocol];
        final provider = AgentProviderBridge(
          RoomSettings(
            llmUrl: 'http://127.0.0.1:${server.port}$path',
            model: 'fixture',
          ),
        )..beginTurn();
        final directory = await Directory.systemTemp.createTemp(
          'agent-stream-protocol-',
        );
        final gateway = ToolGateway(
          workspace: directory.path,
          approve: (_) async => false,
          emit: (_) {},
          commandRunner: SandboxCommandRunner('missing'),
        )..begin();
        final bridge = AgentBridge(gateway, provider);
        await bridge.start();
        final client = http.Client();
        addTearDown(() async {
          if (!release.isCompleted) release.complete();
          client.close();
          await bridge.dispose();
          await server.close(force: true);
          await directory.delete(recursive: true);
        });
        final request =
            http.Request(
                'POST',
                bridge.uri.resolve('/model/v1/chat/completions'),
              )
              ..headers.addAll({
                'Authorization': 'Bearer ${bridge.token}',
                'Content-Type': 'application/json',
              })
              ..body = jsonEncode({
                'stream': true,
                'messages': [
                  {'role': 'user', 'content': '核对'},
                ],
                'tools': [
                  {
                    'type': 'function',
                    'function': {
                      'name': 'web_search',
                      'parameters': roomReadTools.first['inputSchema'],
                    },
                  },
                ],
              });
        final response = await client.send(request);
        expect(response.statusCode, 200);
        final first = Completer<void>(),
            complete = Completer<ModelCompletion>();
        var visible = '';
        final subscription =
            decodeModelStream(
              response.stream,
              'openai',
              allowTools: true,
            ).listen(
              (event) {
                if (event.type == 'text') {
                  visible += event.text;
                  if (!first.isCompleted) first.complete();
                }
                if (event.type == 'complete') {
                  complete.complete(event.completion);
                }
              },
              onError: (Object error, StackTrace stack) {
                if (!first.isCompleted) first.completeError(error, stack);
                if (!complete.isCompleted) complete.completeError(error, stack);
              },
            );
        await first.future.timeout(const Duration(seconds: 5));
        expect(release.isCompleted, false);
        expect(complete.isCompleted, false);
        expect(visible, startsWith('我会'));
        release.complete();
        final value = await complete.future.timeout(const Duration(seconds: 5));
        await subscription.cancel();
        expect(visible, '我会检查。');
        expect(visible, isNot(contains(privateState)));
        expect(value.usage.values, contains(3));
        final result = await provider.complete({
          'messages': [
            {'role': 'user', 'content': '核对'},
            {
              'role': 'assistant',
              'content': value.reply,
              'tool_calls': value.calls
                  .map(
                    (c) => {
                      ...c.openAi,
                      'function': {
                        ...c.openAi['function'],
                        'arguments': '{ "query" : "月读空间" }',
                      },
                    },
                  )
                  .toList(),
            },
            {
              'role': 'tool',
              'tool_call_id': value.calls.single.id,
              'content': '{"declined":true}',
            },
          ],
        });
        expect(result['choices'][0]['message']['content'], '完成。');
        expect(requests, 2);
        final continuation = seen.last;
        if (protocol != 'ollama') {
          expect(jsonEncode(continuation), contains(privateState));
        }
        if (protocol == 'responses') {
          expect(continuation['store'], false);
          expect(
            (continuation['input'] as List)
                .where((i) => i['type'] == 'function_call_output')
                .single['call_id'],
            value.calls.single.id,
          );
        }
        if (protocol == 'anthropic') {
          expect(
            continuation['messages'].last['content'].single['is_error'],
            true,
          );
        }
        if (protocol == 'ollama') {
          expect(continuation['messages'].last['tool_name'], 'web_search');
          expect(
            (continuation['messages'] as List)
                .where((m) => m['role'] == 'assistant')
                .single['thinking'],
            privateState,
          );
        }
        if (finished.isCompleted) await finished.future;
      },
    );
    test(
      '$protocol bounded Room tool loop deduplicates read actions and aggregates usage',
      () async {
        var requests = 0, executions = 0;
        final client =
            LlmClient(
                clientFactory: () => MockClient((req) async {
                  final body = jsonDecode(req.body);
                  requests++;
                  if (requests > 1) {
                    expect(jsonEncode(body), contains('tool reference'));
                    if (protocol != 'ollama') {
                      expect(jsonEncode(body), contains(privateState));
                    }
                  }
                  if (requests < 3) {
                    return http.Response(
                      jsonEncode(fixture(protocol, id: 'read$requests')),
                      200,
                      headers: {'content-type': 'application/json'},
                    );
                  }
                  expect(body['tools'], isNull);
                  return http.Response(
                    jsonEncode(switch (protocol) {
                      'responses' => {
                        'status': 'completed',
                        'output_text': '已核对。',
                      },
                      'anthropic' => {
                        'content': [
                          {'type': 'text', 'text': '已核对。'},
                        ],
                        'stop_reason': 'end_turn',
                      },
                      'ollama' => {
                        'message': {'content': '已核对。'},
                        'done': true,
                      },
                      _ => {
                        'choices': [
                          {
                            'message': {'content': '已核对。'},
                            'finish_reason': 'stop',
                          },
                        ],
                      },
                    }),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }),
              )
              ..tools = [roomReadTools.first]
              ..executeTool = (call) async {
                executions++;
                return {'content': 'tool reference', 'isError': false};
              };
        final path = {
          'openai': '/chat/completions',
          'responses': '/responses',
          'anthropic': '/messages',
          'ollama': '/api/chat',
        }[protocol];
        final reply = await client
            .reply(
              RoomSettings(
                model: 'fixture',
                llmUrl: 'https://models.example$path',
              ),
              [],
              '核对',
            )
            .join();
        expect(reply, endsWith('已核对。'));
        expect(requests, 3);
        expect(executions, 1);
        expect(client.lastAgentRounds, 3);
      },
    );
  }
  test('OpenRouter Claude uses endpoint protocol; Anthropic compatible roots use native credentials', () {
    expect(
      roomProtocol(
        roomChatEndpoint('https://openrouter.ai/api/v1/chat/completions'),
      ),
      'openai',
    );
    final uri = roomChatEndpoint('https://api.minimaxi.com/anthropic');
    expect(uri.path, '/anthropic/v1/messages');
    expect(
      roomChatHeaders(const RoomSettings(apiKey: 'secret'), uri)['x-api-key'],
      'secret',
    );
    expect(
      roomChatHeaders(
        const RoomSettings(apiKey: 'secret'),
        uri,
      )['anthropic-version'],
      '2023-06-01',
    );
  });
  test('Anthropic emits initial text exactly once before deltas', () async {
    final events = await decodeModelStream(
      fragmented(
        [
          sse({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {'type': 'text', 'text': '开始'},
          }),
          sse({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {'type': 'text_delta', 'text': '完成'},
          }),
          sse({'type': 'message_stop'}),
        ].join(),
      ),
      'anthropic',
    ).toList();
    expect(
      events.where((e) => e.type == 'text').map((e) => e.text).join(),
      '开始完成',
    );
    expect(events.last.completion!.reply, '开始完成');
  });
  test('unterminated SSE is bounded before JSON parsing', () async {
    await expectLater(
      modelFrames(fragmented('data: ${'月' * 3000}'), eventBytes: 100).toList(),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('Ollama retains separate streamed calls and private thinking in continuation only', () async {
    final wire = [
      {
        'message': {
          'thinking': privateState,
          'tool_calls': [
            {
              'function': {
                'index': 0,
                'name': 'web_search',
                'arguments': {'query': '月读'},
              },
            },
          ],
        },
        'done': false,
      },
      {
        'message': {
          'tool_calls': [
            {
              'function': {
                'index': 1,
                'name': 'web_search',
                'arguments': {'query': '星空'},
              },
            },
          ],
        },
        'done': false,
      },
      {
        'message': {'content': '正在核对。'},
        'done': true,
      },
    ].map((chunk) => '${jsonEncode(chunk)}\n').join();
    final events = await decodeModelStream(
      fragmented(wire),
      'ollama',
      allowTools: true,
    ).toList();
    final value = events.last.completion!;
    expect(value.calls, hasLength(2));
    expect(value.calls.map((c) => c.id).toSet(), hasLength(2));
    expect(
      events.where((e) => e.type == 'text').map((e) => e.text).join(),
      '正在核对。',
    );
    final body = modelWithTools(
      {'messages': []},
      'ollama',
      [],
      [
        {
          'continuation': value.continuation,
          'results': [
            for (final call in value.calls)
              {
                'id': call.id,
                'name': call.name,
                'content': 'ok',
                'isError': false,
              },
          ],
        },
      ],
    );
    expect(body['messages'].first['thinking'], privateState);
    expect(body['messages'].last['tool_name'], 'web_search');
  });
  test('Responses output-item and argument events survive an omitted terminal output', () async {
    final events = await decodeModelStream(
      fragmented(
        [
          sse({
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {'type': 'reasoning', 'encrypted_content': privateState},
          }),
          sse({
            'type': 'response.output_item.added',
            'output_index': 1,
            'item': {
              'type': 'function_call',
              'call_id': 'read1',
              'name': 'web_search',
              'arguments': '',
            },
          }),
          sse({
            'type': 'response.function_call_arguments.delta',
            'output_index': 1,
            'delta': '{"query":"月读"}',
          }),
          sse({
            'type': 'response.completed',
            'response': {'status': 'completed'},
          }),
        ].join(),
      ),
      'responses',
      allowTools: true,
    ).toList();
    expect(events.last.completion!.calls.single.arguments, '{"query":"月读"}');
    expect(jsonEncode(events.last.completion!.items), contains(privateState));
  });
  test('stream cannot change an existing tool call ID', () async {
    await expectLater(
      decodeModelStream(
        fragmented(
          [
            sse({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'one',
                        'function': {'name': 'fs_read', 'arguments': '{'},
                      },
                    ],
                  },
                },
              ],
            }),
            sse({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'two',
                        'function': {'arguments': '}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            }),
          ].join(),
        ),
        'openai',
        allowTools: true,
      ).toList(),
      throwsA(isA<ApiFailure>()),
    );
  });
  test('native results require explicit text and a boolean failure flag', () {
    final value = ModelCompletion.json(
      fixture('openai'),
      'openai',
      allowTools: true,
    );
    expect(
      () => modelWithTools(
        {'messages': []},
        'openai',
        [],
        [
          {
            'continuation': value.continuation,
            'results': [
              {
                'id': 'read1',
                'name': 'web_search',
                'content': {},
                'isError': 'false',
              },
            ],
          },
        ],
      ),
      throwsA(isA<ApiFailure>()),
    );
  });
  test(
    'Room caches an uncertain failed read instead of executing it twice',
    () async {
      var requests = 0, executions = 0;
      final client =
          LlmClient(
              clientFactory: () => MockClient((req) async {
                final body = jsonDecode(req.body);
                requests++;
                if (requests > 1) {
                  expect(jsonEncode(body), contains('TOOL_FAILED'));
                }
                return http.Response(
                  jsonEncode(
                    requests < 3
                        ? fixture('openai', id: 'read$requests')
                        : {
                            'choices': [
                              {
                                'message': {'content': '工具失败，未查询到结果。'},
                                'finish_reason': 'stop',
                              },
                            ],
                          },
                  ),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }),
            )
            ..tools = [roomReadTools.first]
            ..executeTool = (_) async {
              executions++;
              throw const ApiFailure('uncertain connection failure');
            };
      expect(
        await client
            .reply(const RoomSettings(model: 'fixture'), [], '核对')
            .join(),
        endsWith('工具失败，未查询到结果。'),
      );
      expect(executions, 1);
      expect(requests, 3);
    },
  );
  test(
    'gateway never replays a failed operation with the same call ID',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'gateway-failed-protocol-',
      );
      addTearDown(() => dir.delete(recursive: true));
      var calls = 0;
      final gateway = ToolGateway(
        workspace: dir.path,
        approve: (_) async => false,
        emit: (_) {},
        commandRunner: SandboxCommandRunner('missing'),
        additional: [
          AgentTool('fail', 'fixture', {}, [], (_) async {
            calls++;
            throw const ApiFailure('uncertain failure');
          }),
        ],
      )..begin();
      await expectLater(
        gateway.call('fail', {}, callId: 'one'),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        gateway.call('fail', {}, callId: 'one'),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 1);
    },
  );
  test(
    'malformed, duplicate and excessive tool calls stop before execution',
    () {
      for (final calls in [
        [callJson('same', 'fs_read', {}), callJson('same', 'fs_read', {})],
        List.generate(7, (i) => callJson('call$i', 'fs_read', {})),
        [callJson('invalid id', 'fs_read', {})],
        [
          {
            'id': 'call1',
            'function': {'name': 'fs_read', 'arguments': '{'},
          },
        ],
      ]) {
        expect(
          () => ModelCompletion.json(
            {
              'message': {'tool_calls': calls},
            },
            'openai',
            allowTools: true,
          ),
          throwsA(anyOf(isA<ApiFailure>(), isA<FormatException>())),
        );
      }
    },
  );
  test(
    'Responses failed terminal payload cannot become a completed reply',
    () async {
      await expectLater(
        decodeModelStream(
          fragmented(
            sse({'type': 'response.output_text.delta', 'delta': 'partial'}) +
                sse({
                  'type': 'response.completed',
                  'response': {
                    'status': 'incomplete',
                    'output_text': 'partial',
                  },
                }),
          ),
          'responses',
        ).toList(),
        throwsA(isA<ModelIncompleteFailure>()),
      );
    },
  );
  test('cancel during a tool prevents any next model request', () async {
    var requests = 0;
    final started = Completer<void>(), stopped = Completer<void>();
    final client =
        LlmClient(
            clientFactory: () => MockClient((req) async {
              requests++;
              return http.Response(
                jsonEncode(fixture('openai')),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          )
          ..tools = [roomReadTools.first]
          ..executeTool = (call) async {
            started.complete();
            await stopped.future;
            throw const ApiFailure('cancel');
          };
    client.cancelTools = () {
      if (started.isCompleted && !stopped.isCompleted) stopped.complete();
    };
    final pending = client
        .reply(const RoomSettings(model: 'fixture'), [], 'search')
        .toList();
    await started.future;
    client.cancel();
    await pending;
    expect(requests, 1);
  });
  test(
    'image tool only receives the current attachment and refuses model URLs',
    () {
      final settings = const RoomSettings(
        options: {'mcpEnabled': true, 'mcpEndpoint': 'https://tools.example'},
      );
      expect(
        allowedRoomModelTools(settings, hasImage: false).map((t) => t['name']),
        ['web_search'],
      );
      expect(
        () => roomModelArguments(
          ModelCall(
            'image1',
            'understand_image',
            '{"prompt":"look","image_url":"https://evil.example"}',
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(RoomTools().allowed(settings, 'shell'), false);
    },
  );
  test('gateway exactly-once ledger survives uncertain failure and rejects changed payload', () async {
    final dir = await Directory.systemTemp.createTemp('gateway-protocol-');
    var calls = 0;
    final gateway = ToolGateway(
      workspace: dir.path,
      approve: (_) async => false,
      emit: (_) {},
      commandRunner: SandboxCommandRunner('missing'),
      additional: [
        AgentTool(
          'count',
          'counter',
          {
            'x': {'type': 'integer'},
          },
          ['x'],
          (args) async {
            calls++;
            return {'ok': true};
          },
        ),
      ],
    )..begin();
    addTearDown(() => dir.delete(recursive: true));
    final first = gateway.call('count', {'x': 1}, callId: 'rpc:1');
    final repeated = gateway.call('count', {'x': 1}, callId: 'rpc:1');
    expect(identical(first, repeated), true);
    await first;
    expect(calls, 1);
    expect(gateway.calls, 1);
    expect(
      () => gateway.call('count', {'x': 2}, callId: 'rpc:1'),
      throwsA(isA<ApiFailure>()),
    );
    gateway.cancel();
    expect(
      () => gateway.call('count', {'x': 1}, callId: 'rpc:1'),
      throwsA(isA<ApiFailure>()),
    );
  });
}
