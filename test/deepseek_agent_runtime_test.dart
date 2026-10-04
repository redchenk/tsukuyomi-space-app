import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/agent/desktop_agent_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';
import 'support/svg_fixture.dart';

void main() {
  const native = bool.fromEnvironment('RUN_AGENT_TESTS');
  test(
    'real OpenCode streams DeepSeek text, writes a large SVG once and keeps reasoning for tool replay',
    () async {
      final root = await Directory.systemTemp.createTemp('agent-deepseek-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finishFirst = Completer<void>();
      final firstText = Completer<void>();
      const privateState = 'PROVIDER_STATE_NOT_PUBLIC_PROGRESS';
      final svg = pelicanSvgFixture();
      var nativeRequests = 0;
      var reasoningReplayed = false;
      Future<void> handle(HttpRequest request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], 'deepseek-reasoner');
        expect(body['stream'], true);
        expect(body['tools'], isNotEmpty);
        nativeRequests++;
        request.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        request.response.bufferOutput = false;
        Future<void> chunk(Map delta, [String? finish]) async {
          request.response.write(
            'data: ${jsonEncode({
              'id': 'deepseek-$nativeRequests',
              'object': 'chat.completion.chunk',
              'created': 1,
              'model': 'deepseek-reasoner',
              'choices': [
                {'index': 0, 'delta': delta, 'finish_reason': finish},
              ],
            })}\n\n',
          );
          await request.response.flush();
        }

        if (nativeRequests == 1) {
          await chunk({'role': 'assistant', 'reasoning_content': privateState});
          await chunk({'content': '我会先检查工作目录'});
          await chunk({'content': '，再保存文件。'});
          await finishFirst.future;
          final tool = (body['tools'] as List).firstWhere(
            (raw) => (raw['function']['name'] as String).endsWith('fs_write'),
          );
          await chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'once',
                'type': 'function',
                'function': {'name': tool['function']['name'], 'arguments': ''},
              },
            ],
          });
          final arguments = jsonEncode({'path': 'pelican.svg', 'content': svg});
          for (var offset = 0; offset < arguments.length; offset += 1024) {
            await chunk({
              'tool_calls': [
                {
                  'index': 0,
                  'function': {
                    'arguments': arguments.substring(
                      offset,
                      offset + 1024 < arguments.length
                          ? offset + 1024
                          : arguments.length,
                    ),
                  },
                },
              ],
            });
          }
          await chunk({}, 'tool_calls');
        } else {
          final assistant = (body['messages'] as List)
              .where((m) => m['role'] == 'assistant')
              .last;
          reasoningReplayed = assistant['reasoning_content'] == privateState;
          expect(reasoningReplayed, true);
          expect(svg.length, greaterThan(65536));
          expect(
            (body['messages'] as List).any((m) => m['role'] == 'tool'),
            true,
          );
          await chunk({
            'role': 'assistant',
            'reasoning_content': 'second provider state',
          });
          await chunk({'content': '**已保存** pelican.svg。'});
          await chunk({'content': '\n\n仅写入一次，没有运行命令。'}, 'stop');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      }

      upstream.listen((request) => unawaited(handle(request)));
      final store = MemoryStorage()
        ..value = RoomSettings(
          model: 'deepseek-reasoner',
          llmUrl: 'http://127.0.0.1:${upstream.port}/chat/completions',
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
        runtimeDataDirectory: '${root.path}/runtime',
        // Cold CI runners need time for the native SDK and MCP discovery.
        // Still hold the response past this budget to verify text cancels it.
        nativeResponseTimeout: const Duration(seconds: 10),
      );
      final workspace = await Directory('${root.path}/workspace').create();
      addTearDown(() async {
        if (!finishFirst.isCompleted) finishFirst.complete();
        await agent.shutdown();
        agent.dispose();
        room.dispose();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      });
      await agent.selectWorkspace(workspace.path);
      agent.addListener(() {
        if (!firstText.isCompleted &&
            (agent.session?.events ?? []).any(
              (event) =>
                  event.type == 'assistant' && event.text.startsWith('我会先检查'),
            )) {
          firstText.complete();
        }
      });
      const task = '保存文件，并说明结果';
      final result = agent.send(task);
      await firstText.future.timeout(const Duration(seconds: 30));
      expect(finishFirst.isCompleted, false);
      expect(await File('${workspace.path}/pelican.svg').exists(), false);
      await Future<void>.delayed(const Duration(seconds: 11));
      expect(agent.status, 'OpenCode');
      expect(nativeRequests, 1);
      finishFirst.complete();
      await result;
      expect(agent.error, isEmpty);
      expect(agent.status, 'OpenCode');
      expect(nativeRequests, 2);
      expect(reasoningReplayed, true);
      expect(svg.length, greaterThan(65536));
      expect(await File('${workspace.path}/pelican.svg').readAsString(), svg);
      final events = agent.session!.events;
      expect(events.where((e) => e.type == 'toolStart'), hasLength(1));
      expect(
        events.where((e) => e.type == 'assistant' && e.text == task),
        isEmpty,
      );
      expect(events.any((e) => e.text.contains(privateState)), false);
      expect(
        events.lastWhere((e) => e.type == 'assistant').text,
        contains('**已保存**'),
      );
    },
    skip: !native,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'automatic mode cancels a silent native request, explains fallback and remembers a working compatible engine',
    () async {
      final root = await Directory.systemTemp.createTemp('agent-silent-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final abandoned = Completer<void>();
      var nativeRequests = 0, structured = 0;
      upstream.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if ((body['tools'] as List? ?? []).isNotEmpty) {
          nativeRequests++;
          request.response.headers.set('Content-Type', 'text/event-stream');
          request.response.bufferOutput = false;
          // Keep-alive and role-only events must not count as meaningful output.
          request.response.write(
            ': keep-alive\n\ndata: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}\n\n',
          );
          await request.response.flush();
          await abandoned.future;
          try {
            await request.response.close();
          } catch (_) {}
          return;
        }
        final action = structured++ % 2 == 0
            ? {
                'type': 'tool',
                'commentary': '我会使用兼容模式保存文件。',
                'name': 'fs_write',
                'arguments': {'path': 'fallback.txt', 'content': 'compatible'},
              }
            : {'type': 'final', 'text': '已保存文件。'};
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': jsonEncode(action)},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
        await request.response.close();
      });
      final store = MemoryStorage()
        ..value = RoomSettings(
          model: 'deepseek-chat',
          llmUrl: 'http://127.0.0.1:${upstream.port}/chat/completions',
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
        runtimeDataDirectory: '${root.path}/runtime',
        nativeResponseTimeout: const Duration(seconds: 5),
      );
      final workspace = await Directory('${root.path}/workspace').create();
      addTearDown(() async {
        abandoned.complete();
        await agent.shutdown();
        agent.dispose();
        room.dispose();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      });
      await agent.selectWorkspace(workspace.path);
      final result = agent.send('保存文件');
      expect(agent.session!.events.last.type, 'user');
      await result.timeout(const Duration(seconds: 25));
      expect(agent.error, isEmpty);
      expect(agent.status, '结构化兼容模式');
      expect(nativeRequests, 1);
      expect(structured, 2);
      expect(
        agent.session!.events.any((e) => e.text == '自动模式等待过久，正在切换兼容模式'),
        true,
      );
      expect(
        await File('${workspace.path}/fallback.txt').readAsString(),
        'compatible',
      );
      await agent.newSession();
      await agent.send('再次保存');
      expect(nativeRequests, 1);
      expect(structured, 4);
    },
    skip: !native,
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a retrying rate-limited native provider is stopped without compatible resubmission',
    () async {
      final root = await Directory.systemTemp.createTemp('agent-rate-limit-');
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var nativeRequests = 0, structured = 0;
      upstream.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if ((body['tools'] as List? ?? []).isEmpty) {
          structured++;
        } else {
          nativeRequests++;
        }
        request.response.statusCode = 429;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'error': {'message': 'rate limited'},
          }),
        );
        await request.response.close();
      });
      final store = MemoryStorage()
        ..value = RoomSettings(
          model: 'deepseek-chat',
          llmUrl: 'http://127.0.0.1:${upstream.port}/chat/completions',
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
        runtimeDataDirectory: '${root.path}/runtime',
        // Windows can spend more than two seconds loading the provider after
        // the OpenCode server is ready, especially beside another runtime test.
        // Exercise a received 429, rather than racing a silent startup timeout.
        nativeResponseTimeout: const Duration(seconds: 10),
      );
      final workspace = await Directory('${root.path}/workspace').create();
      addTearDown(() async {
        await agent.shutdown();
        agent.dispose();
        room.dispose();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      });
      await agent.selectWorkspace(workspace.path);
      await agent.send('保存文件').timeout(const Duration(seconds: 35));
      expect(
        nativeRequests,
        greaterThan(0),
        reason: 'The native request must reach the rate-limited provider',
      );
      expect(agent.error, contains('HTTP 429'));
      expect(structured, 0);
      final count = nativeRequests;
      expect(count, greaterThan(0));
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(nativeRequests, count);
      expect(await workspace.list().length, 0);
    },
    skip: !native,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
