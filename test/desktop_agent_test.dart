import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_types.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_tools.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_binaries.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_provider.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_bridge.dart';
import 'package:tsukuyomi_space_app/core/agent/opencode_agent_runtime.dart';
import 'package:tsukuyomi_space_app/core/agent/structured_agent_runtime.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/agent/desktop_agent_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

import 'package:tsukuyomi_space_app/core/llm_client.dart';

class ScriptedAgentChat implements ChatService {
  ScriptedAgentChat(this.answers);
  final List<String> answers;
  int requests = 0;
  @override
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  ) => Stream.value(answers[requests++]);
  @override
  void cancel() {}
}

class StallingHealthClient extends http.BaseClient {
  StallingHealthClient(this.stall, this.closed);
  final bool Function() stall;
  final void Function() closed;
  final http.Client delegate = http.Client();
  Completer<http.StreamedResponse>? pending;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path == '/global/health' && stall()) {
      pending = Completer<http.StreamedResponse>();
      return pending!.future;
    }
    return delegate.send(request);
  }

  @override
  void close() {
    delegate.close();
    if (pending != null && !pending!.isCompleted) {
      pending!.complete(http.StreamedResponse(const Stream.empty(), 503));
      closed();
    }
  }
}

void main() {
  late Directory temporary, workspace;
  late List<AgentEvent> events;
  late ToolGateway gateway;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tsukuyomi-agent-test-');
    workspace = await Directory('${temporary.path}/workspace').create();
    events = [];
    gateway = ToolGateway(
      workspace: workspace.path,
      approve: (_) async => false,
      emit: events.add,
      commandRunner: SandboxCommandRunner('missing'),
    );
    gateway.begin();
  });
  tearDown(() async {
    gateway.cancel();
    await temporary.delete(recursive: true);
  });

  test('runtime cleanup retries transient Windows sharing locks', () async {
    final private = await Directory('${temporary.path}/locked').create();
    await File('${private.path}/state').writeAsString('temporary');
    var attempts = 0;
    await deleteAgentTemporaryDirectory(
      private,
      retryWindowsSharingViolations: true,
      deleteDirectory: (directory) async {
        if (++attempts <= 2) {
          throw PathAccessException(
            directory.path,
            const OSError('File is in use', 32),
            'Sharing violation',
          );
        }
        await directory.delete(recursive: true);
      },
    );
    expect(attempts, 3);
    expect(await private.exists(), false);
  });

  test('runtime cleanup surfaces unrelated filesystem errors', () async {
    var attempts = 0;
    await expectLater(
      deleteAgentTemporaryDirectory(
        workspace,
        retryWindowsSharingViolations: true,
        deleteDirectory: (directory) async {
          attempts++;
          throw FileSystemException(
            'Unrelated failure',
            directory.path,
            const OSError('Invalid argument', 87),
          );
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempts, 1);
    expect(await workspace.exists(), true);
  });

  test('runtime cleanup surfaces a persistent sharing lock', () async {
    var attempts = 0;
    await expectLater(
      deleteAgentTemporaryDirectory(
        workspace,
        retryWindowsSharingViolations: true,
        deleteDirectory: (directory) async {
          attempts++;
          throw PathAccessException(
            directory.path,
            const OSError('File remains in use', 32),
            'Persistent lock',
          );
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(attempts, 7);
    expect(await workspace.exists(), true);
  });

  test('real file roundtrip is scoped and emits an actual diff', () async {
    await gateway.call('fs_write', {
      'path': 'notes/test.md',
      'content': 'hello 月読',
    });
    expect(
      await File('${workspace.path}/notes/test.md').readAsString(),
      'hello 月読',
    );
    expect(
      (await gateway.call('fs_read', {'path': 'notes/test.md'}))['content'],
      'hello 月読',
    );
    expect(events.where((e) => e.type == 'diff').single.data['before'], '');
  });
  for (final status in [400, 401, 429, 500]) {
    test(
      'local model bridge preserves HTTP $status with a nonempty error body',
      () async {
        final bridge = AgentBridge(
          gateway,
          AgentProviderBridge(
            const RoomSettings(model: 'fixture'),
            clientFactory: () =>
                MockClient((_) async => http.Response('', status)),
          ),
        );
        await bridge.start();
        try {
          final response = await http.post(
            bridge.uri.resolve('/model/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer ${bridge.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'messages': [
                {'role': 'user', 'content': 'hello'},
              ],
            }),
          );
          expect(response.statusCode, status);
          expect(
            jsonDecode(response.body)['error']['message'],
            contains('HTTP $status'),
          );
        } finally {
          await bridge.dispose();
        }
      },
    );
  }
  test('traversal and symlink escapes require approval', () async {
    final outside = File('${temporary.path}/outside.txt');
    await outside.writeAsString('private');
    await expectLater(
      gateway.call('fs_read', {'path': '../outside.txt'}),
      throwsA(isA<ApiFailure>()),
    );
    if (!Platform.isWindows) {
      await Link('${workspace.path}/linked.txt').create(outside.path);
      await expectLater(
        gateway.call('fs_write', {'path': 'linked.txt', 'content': 'changed'}),
        throwsA(isA<ApiFailure>()),
      );
      expect(await outside.readAsString(), 'private');
    }
  });
  test(
    'schema rejects unknown parameters and tools without executing',
    () async {
      await expectLater(
        gateway.call('fs_write', {
          'path': 'test',
          'content': 'x',
          'extra': true,
        }),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        gateway.call('arbitrary_shell', {}),
        throwsA(isA<ApiFailure>()),
      );
      expect(await File('${workspace.path}/test').exists(), false);
    },
  );
  test(
    'cancel invalidates a pending approval even when it later resolves true',
    () async {
      final answer = Completer<bool>(), asked = Completer<void>();
      final controlled = ToolGateway(
        workspace: workspace.path,
        approve: (_) {
          asked.complete();
          return answer.future;
        },
        emit: events.add,
        commandRunner: SandboxCommandRunner('missing'),
        additional: [
          AgentTool(
            'publish',
            'publish',
            {},
            [],
            (_) async => 'bad',
            confirm: true,
          ),
        ],
      );
      controlled.begin();
      final call = controlled.call('publish', {});
      await asked.future;
      controlled.cancel();
      answer.complete(true);
      await expectLater(call, throwsA(isA<ApiFailure>()));
      expect(events.where((e) => e.type == 'toolResult'), isEmpty);
    },
  );
  test(
    'structured mode executes validated actions, repairs once, then answers',
    () async {
      final chat = ScriptedAgentChat([
        'plain invalid response',
        '{"type":"tool","name":"fs_write","arguments":{"path":"result.md","content":"完成"}}',
        '{"type":"final","text":"已保存"}',
      ]);
      final runtime = StructuredAgentRuntime(gateway, chat: chat);
      await runtime.send(
        AgentSession(id: 'test', owner: 'guest', workspace: workspace.path),
        'write a note',
        const RoomSettings(model: 'fixture'),
        events.add,
      );
      expect(await File('${workspace.path}/result.md').readAsString(), '完成');
      expect(chat.requests, 3);
      expect(events.last.text, '已保存');
    },
  );
  test(
    'two malformed actions stop; no text is executed as a command',
    () async {
      final runtime = StructuredAgentRuntime(
        gateway,
        chat: ScriptedAgentChat([
          'rm -rf /',
          '{"type":"tool","name":"unknown","arguments":{}}',
        ]),
      );
      await expectLater(
        runtime.send(
          AgentSession(id: 'test', owner: 'guest', workspace: workspace.path),
          'task',
          const RoomSettings(model: 'fixture'),
          events.add,
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        events.where((e) => e.type == 'toolStart' || e.type == 'toolResult'),
        isEmpty,
      );
      expect(events.where((e) => e.type == 'info'), hasLength(1));
    },
  );

  for (final protocol in ['openai', 'responses', 'anthropic', 'ollama']) {
    test(
      'native provider conversion preserves tool arguments and results: $protocol',
      () async {
        final endpoint = switch (protocol) {
          'responses' => 'https://provider.test/v1/responses',
          'anthropic' => 'https://provider.test/v1/messages',
          'ollama' => 'http://localhost:11434/api/chat',
          _ => 'https://provider.test/v1/chat/completions',
        };
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], 'configured-model');
          expect(body['stream'], false);
          expect(body['tools'], isNotEmpty);
          final data = switch (protocol) {
            'responses' => {
              'output': [
                {
                  'type': 'function_call',
                  'call_id': 'call1',
                  'name': 'fs_read',
                  'arguments': '{"path":"test"}',
                },
              ],
            },
            'anthropic' => {
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'call1',
                  'name': 'fs_read',
                  'input': {'path': 'test'},
                },
              ],
            },
            'ollama' => {
              'message': {
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call1',
                    'function': {
                      'name': 'fs_read',
                      'arguments': {'path': 'test'},
                    },
                  },
                ],
              },
            },
            _ => {
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'tool_calls': [
                      {
                        'id': 'call1',
                        'type': 'function',
                        'function': {
                          'name': 'fs_read',
                          'arguments': '{"path":"test"}',
                        },
                      },
                    ],
                  },
                },
              ],
            },
          };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final bridge = AgentProviderBridge(
          RoomSettings(
            llmUrl: endpoint,
            model: 'configured-model',
            apiKey: 'private-key',
          ),
          clientFactory: () => client,
        );
        final response = await bridge.complete({
          'messages': [
            {'role': 'system', 'content': 'tools'},
            {'role': 'user', 'content': 'read file'},
            {
              'role': 'assistant',
              'tool_calls': [
                {
                  'id': 'before',
                  'function': {
                    'name': 'fs_read',
                    'arguments': '{"path":"old"}',
                  },
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'before',
              'content': 'old contents',
            },
          ],
          'tools': [
            {
              'type': 'function',
              'function': {
                'name': 'fs_read',
                'description': 'read',
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'path': {'type': 'string'},
                  },
                  'required': ['path'],
                },
              },
            },
          ],
        });
        expect(response['choices'][0]['finish_reason'], 'tool_calls');
        expect(
          response['choices'][0]['message']['tool_calls'][0]['function']['arguments'],
          '{"path":"test"}',
        );
      },
    );
  }

  test(
    'gateway enforces twenty actions and cannot execute without a sandbox',
    () async {
      for (var i = 0; i < 20; i++) {
        await gateway.call('fs_list', {});
      }
      await expectLater(
        gateway.call('fs_list', {}),
        throwsA(isA<ApiFailure>()),
      );
      gateway.begin();
      await expectLater(
        gateway.call('command', {'command': 'echo must not execute'}),
        throwsA(isA<ApiFailure>()),
      );
    },
  );
  test(
    'JSON schema validates nullable enum, nested bounds and reference failures',
    () {
      validateArguments({
        'type': ['integer', 'null'],
        'minimum': 0,
      }, null);
      expect(
        () => validateArguments({'type': 'integer', 'minimum': 0}, -1),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => validateArguments({
          'enum': ['read', 'write'],
        }, 'delete'),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        () => validateArguments({r'$ref': '#/unknown'}, {}),
        throwsA(isA<ApiFailure>()),
      );
    },
  );

  for (final protocol in ['openai', 'responses', 'anthropic', 'ollama']) {
    test(
      'structured fallback uses the configured real HTTP protocol: $protocol',
      () async {
        var requests = 0;
        final client = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], 'configured-model');
          final action = requests++ == 0
              ? {
                  'type': 'tool',
                  'name': 'fs_write',
                  'arguments': {
                    'path': 'compat.txt',
                    'content': 'compat $protocol',
                  },
                }
              : {'type': 'final', 'text': 'Done'};
          final text = jsonEncode(action);
          final payload = switch (protocol) {
            'responses' => {
              'status': 'completed',
              'output': [
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': text},
                  ],
                },
              ],
            },
            'anthropic' => {
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': text},
              ],
            },
            'ollama' => {
              'done': true,
              'message': {'role': 'assistant', 'content': text},
            },
            _ => {
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': text},
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
        });
        final runtime = StructuredAgentRuntime(
          gateway,
          chat: LlmClient(clientFactory: () => client),
        );
        await runtime.send(
          AgentSession(id: 'compat', owner: 'guest', workspace: workspace.path),
          'Save a note',
          RoomSettings(
            model: 'configured-model',
            llmUrl: switch (protocol) {
              'responses' => 'https://provider.test/v1/responses',
              'anthropic' => 'https://provider.test/v1/messages',
              'ollama' => 'http://localhost:11434/api/chat',
              _ => 'https://provider.test/v1/chat/completions',
            },
          ),
          events.add,
        );
        expect(requests, 2);
        expect(
          await File('${workspace.path}/compat.txt').readAsString(),
          'compat $protocol',
        );
      },
    );
  }

  const native = bool.fromEnvironment('RUN_AGENT_TESTS');
  test(
    'bundled Codex enforces scoped commands and cancellation, or refuses unavailable Windows PSEC',
    () async {
      final binaries = await AgentBinaries.locate();
      final runner = SandboxCommandRunner(binaries.codex);
      addTearDown(runner.dispose);
      final Map<String, dynamic> result;
      try {
        result = await runner.run(
          workspace.path,
          Platform.isWindows
              ? 'echo hello>inside.txt'
              : 'printf hello > inside.txt',
        );
      } on ApiFailure catch (error) {
        // Windows Server 2022 lacks PSEC. Only this explicit capability refusal
        // is accepted; other failures still fail the integration test.
        final detail = error.toString();
        if (!Platform.isWindows ||
            !(detail.contains(
                  'native MXC is unavailable on this Windows build',
                ) ||
                detail.contains(
                  'native MXC is unavailable on this executor',
                ))) {
          rethrow;
        }
        expect(await File('${workspace.path}/inside.txt').exists(), false);
        expect(events.where((event) => event.type == 'toolResult'), isEmpty);
        stderr.writeln(
          'Windows host lacks PSEC: verified fail-closed refusal with no file write.',
        );
        return;
      }
      expect(result['exitCode'], 0, reason: result['stderr'].toString());
      expect(await File('${workspace.path}/inside.txt').exists(), true);
      final outside = File('${temporary.path}/outside.txt');
      await outside.writeAsString('outside-private');
      final escaped = await runner.run(
        workspace.path,
        Platform.isWindows
            ? 'echo bad>"${outside.path}"'
            : "printf bad > '${outside.path}'",
      );
      // Codex's Linux restricted-read root is a fresh tmpfs. A command can
      // create a shadow file there, but must never change the actual host file.
      if (!Platform.isLinux) expect(escaped['exitCode'], isNot(0));
      expect(await outside.readAsString(), 'outside-private');
      final readCommand = Platform.isWindows
          ? 'type "${outside.path}"'
          : "cat '${outside.path}'";
      final deniedRead = await runner.run(workspace.path, readCommand);
      expect(
        deniedRead['exitCode'],
        isNot(0),
        reason: 'The default sandbox must deny reads outside the selected workspace.',
      );
      final allowedRead = await runner.run(
        workspace.path,
        readCommand,
        readRoots: [temporary.path],
      );
      expect(
        allowedRead['exitCode'],
        0,
        reason: allowedRead['stderr'].toString(),
      );
      expect(allowedRead['stdout'], contains('outside-private'));
      final future = runner.run(
        workspace.path,
        Platform.isWindows
            ? 'ping -n 30 127.0.0.1>nul & echo late>cancelled.txt'
            : 'sleep 30 & wait; printf late > cancelled.txt',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final cancelled = expectLater(future, throwsA(isA<ApiFailure>()));
      await runner.cancel();
      await cancelled;
      expect(await File('${workspace.path}/cancelled.txt').exists(), false);
    },
    skip: !native,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  for (final protocol in ['openai', 'responses', 'anthropic', 'ollama']) {
    test(
      'real OpenCode, native MCP gateway, process recovery without replay: $protocol',
      () async {
        final binaries = await AgentBinaries.locate();
        var requests = 0;
        final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        provider.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests++;
          final messages =
              body['messages'] as List? ?? body['input'] as List? ?? [];
          final toolResult = messages.any(
            (m) =>
                m['role'] == 'tool' ||
                m['type'] == 'function_call_output' ||
                (m['content'] is List &&
                    (m['content'] as List).any(
                      (c) => c['type'] == 'tool_result',
                    )),
          );
          final tools = body['tools'] as List? ?? [];
          final selected = tools.cast<Map>().firstWhere(
            (t) => ((t['function']?['name'] ?? t['name']) as String).endsWith(
              'fs_write',
            ),
          );
          final name = selected['function']?['name'] ?? selected['name'];
          final message = toolResult
              ? {'role': 'assistant', 'content': 'Saved fixture file.'}
              : {
                  'role': 'assistant',
                  'content': '',
                  'tool_calls': [
                    {
                      'id': 'call_fixture',
                      'type': 'function',
                      'function': {
                        'name': name,
                        'arguments':
                            '{"path":"agent.txt","content":"native gateway"}',
                      },
                    },
                  ],
                };
          final arguments = {'path': 'agent.txt', 'content': 'native gateway'};
          final payload = switch (protocol) {
            'responses' => {
              'id': 'fixture',
              'status': 'completed',
              'output': [
                toolResult
                    ? {
                        'type': 'message',
                        'role': 'assistant',
                        'content': [
                          {
                            'type': 'output_text',
                            'text': 'Saved fixture file.',
                          },
                        ],
                      }
                    : {
                        'type': 'function_call',
                        'call_id': 'call_fixture',
                        'name': name,
                        'arguments': jsonEncode(arguments),
                      },
              ],
            },
            'anthropic' => {
              'id': 'fixture',
              'type': 'message',
              'role': 'assistant',
              'stop_reason': toolResult ? 'end_turn' : 'tool_use',
              'content': [
                toolResult
                    ? {'type': 'text', 'text': 'Saved fixture file.'}
                    : {
                        'type': 'tool_use',
                        'id': 'call_fixture',
                        'name': name,
                        'input': arguments,
                      },
              ],
            },
            'ollama' => {
              'done': true,
              'message': toolResult
                  ? {'role': 'assistant', 'content': 'Saved fixture file.'}
                  : {
                      'role': 'assistant',
                      'content': '',
                      'tool_calls': [
                        {
                          'function': {'name': name, 'arguments': arguments},
                        },
                      ],
                    },
            },
            _ => {
              'id': 'fixture',
              'object': 'chat.completion',
              'choices': [
                {
                  'index': 0,
                  'message': message,
                  'finish_reason': toolResult ? 'stop' : 'tool_calls',
                },
              ],
              'usage': {
                'prompt_tokens': 1,
                'completion_tokens': 1,
                'total_tokens': 2,
              },
            },
          };
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(payload));
          await request.response.close();
        });
        final settings = RoomSettings(
          model: 'fixture',
          llmUrl:
              'http://127.0.0.1:${provider.port}${switch (protocol) {
                'responses' => '/v1/responses',
                'anthropic' => '/v1/messages',
                'ollama' => '/api/chat',
                _ => '/v1/chat/completions',
              }}',
        );
        final session = AgentSession(
          id: 'integration',
          owner: 'fixture',
          workspace: workspace.path,
        );
        var stalledHealth = false, closedHealth = false;
        final runtime = OpenCodeAgentRuntime(
          binaries,
          gateway,
          settings,
          dataDirectory: '${temporary.path}/runtime-data',
          clientFactory: protocol != 'openai'
              ? null
              : () => StallingHealthClient(() {
                  if (stalledHealth) return false;
                  stalledHealth = true;
                  return true;
                }, () => closedHealth = true),
        );
        try {
          await runtime.send(
            session,
            'Write agent.txt using the provided tool.',
            settings,
            events.add,
          );
          expect(
            await File('${workspace.path}/agent.txt').readAsString(),
            'native gateway',
          );
          expect(events.where((e) => e.type == 'toolResult'), hasLength(1));
          if (protocol == 'openai') {
            expect(stalledHealth, true);
            expect(closedHealth, true);
          }
          expect(
            events.where((e) => e.type == 'assistant').last.text,
            'Saved fixture file.',
          );
          final before = requests;
          await runtime.resume(session);
          expect(requests, before);
          await runtime.dispose();
          final recovered = OpenCodeAgentRuntime(
            binaries,
            gateway,
            settings,
            dataDirectory: '${temporary.path}/runtime-data',
          );
          try {
            await recovered.resume(session);
            expect(requests, before);
            session.events.add(AgentEvent('assistant', 'Saved fixture file.'));
            session.nativeId = 'ses_missing_fixture';
            await recovered.resume(session);
            expect(
              requests,
              before,
              reason: 'Missing server session stores transcript without running any model or tool.',
            );
            expect(
              await File('${workspace.path}/agent.txt').readAsString(),
              'native gateway',
            );
          } finally {
            await recovered.dispose();
          }
        } finally {
          await runtime.dispose();
          await provider.close(force: true);
        }
      },
      skip: !native,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
  for (final responseKind in [
    'unsupported',
    'empty400',
    'empty422',
    'unauthorized',
    'aftertool400',
  ]) {
    test(
      'desktop automatic mode safely handles $responseKind before executing tools',
      () async {
        var requests = 0, structured = 0;
        final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        provider.listen((request) async {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          requests++;
          request.response.headers.contentType = ContentType.json;
          if ((body['tools'] as List? ?? []).isNotEmpty) {
            request.response.statusCode = responseKind == 'unauthorized'
                ? 401
                : responseKind == 'empty422'
                ? 422
                : 400;
            if (responseKind == 'aftertool400' && requests == 1) {
              request.response.statusCode = 200;
              final tool = (body['tools'] as List).firstWhere(
                (tool) =>
                    (tool['function']['name'] as String).endsWith('fs_write'),
              );
              request.response.write(
                jsonEncode({
                  'choices': [
                    {
                      'message': {
                        'role': 'assistant',
                        'content': '',
                        'tool_calls': [
                          {
                            'id': 'single-write',
                            'type': 'function',
                            'function': {
                              'name': tool['function']['name'],
                              'arguments': jsonEncode({
                                'path': 'auto.txt',
                                'content': 'exactly once',
                              }),
                            },
                          },
                        ],
                      },
                      'finish_reason': 'tool_calls',
                    },
                  ],
                }),
              );
            }
            if (responseKind == 'unsupported') {
              request.response.write(
                jsonEncode({
                  'error': {'message': 'tools unsupported'},
                }),
              );
            }
          } else {
            final action = structured++ == 0
                ? {
                    'type': 'tool',
                    'name': 'fs_write',
                    'arguments': {
                      'path': 'auto.txt',
                      'content': 'auto fallback',
                    },
                  }
                : {'type': 'final', 'text': 'Finished'};
            request.response.write(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': jsonEncode(action),
                    },
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
          }
          await request.response.close();
        });
        final store = MemoryStorage()
          ..value = RoomSettings(
            model: 'fixture',
            llmUrl: 'http://127.0.0.1:${provider.port}/v1/chat/completions',
          );
        final room = RoomController(
          storage: store,
          chat: FakeChat(),
          site: FakeSite(),
          voice: SilentVoice(),
        );
        await room.initialize();
        final agent = DesktopAgentController(
          room,
          runtimeDataDirectory: '${temporary.path}/controller-runtime',
        );
        try {
          await agent.selectWorkspace(workspace.path);
          expect(agent.error, isEmpty);
          expect(requests, 0);
          await agent.send('Save auto.txt');
          if (responseKind == 'unauthorized') {
            expect(agent.error, contains('HTTP 401'));
            expect(structured, 0);
            expect(requests, 1);
            expect(await File('${workspace.path}/auto.txt').exists(), false);
            return;
          }
          if (responseKind == 'aftertool400') {
            expect(agent.error, contains('HTTP 400'));
            expect(structured, 0);
            expect(requests, 2);
            expect(
              await File('${workspace.path}/auto.txt').readAsString(),
              'exactly once',
            );
            expect(agent.status, 'OpenCode');
            return;
          }
          expect(agent.error, isEmpty);
          expect(agent.status, '结构化兼容模式');
          expect(structured, 2);
          expect(
            await File('${workspace.path}/auto.txt').readAsString(),
            'auto fallback',
          );
          await agent.shutdown();
          final completedRequests = requests;
          await agent.send('This task must never run after shutdown');
          expect(requests, completedRequests);
          expect(
            store.drafts.keys.any((key) => key.startsWith('agent-session:')),
            true,
          );
          await agent.shutdown();
        } finally {
          await agent.shutdown();
          agent.dispose();
          room.dispose();
          await provider.close(force: true);
        }
      },
      skip: !native,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
