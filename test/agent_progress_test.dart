import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tsukuyomi_space_app/core/agent/agent_bridge.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_progress.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_provider.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_tools.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_types.dart';
import 'package:tsukuyomi_space_app/core/agent/structured_agent_runtime.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/locale_controller.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/features/agent/agent_panel.dart';
import 'package:tsukuyomi_space_app/features/agent/desktop_agent_controller.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

class _ControlledChat implements ChatService {
  final stream = StreamController<String>();
  bool cancelled = false;
  @override
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  ) => stream.stream;
  @override
  void cancel() {
    cancelled = true;
    unawaited(stream.close());
  }
}

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_UI');
  setUpAll(() async {
    if (!capture || !Platform.isMacOS) return;
    final font =
        Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'));
    await (FontLoader('Roboto')..addFont(
          Future.value(ByteData.sublistView(await font.readAsBytes())),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test('JSON display preview handles Chinese, escapes and split surrogate pairs without exposing arguments', () {
    final preview = AgentJsonPreview();
    const source =
        r'{"arguments":{"text":"never display","commentary":"hidden"},"type":"final","text":"中文\n\"引用\"\uD83D\uDE80"}';
    for (final code in source.codeUnits) {
      preview.add(String.fromCharCode(code));
    }
    expect(preview.type, 'final');
    expect(preview.value('text'), '中文\n"引用"🚀');
    expect(preview.value('commentary'), isEmpty);
  });

  test('structured final answer is visible before its JSON or response is complete', () async {
    final root = await Directory.systemTemp.createTemp('agent-progress-');
    final events = <AgentEvent>[];
    final chat = _ControlledChat();
    final gateway = ToolGateway(
      workspace: root.path,
      approve: (_) async => false,
      emit: events.add,
      commandRunner: SandboxCommandRunner('missing'),
    )..begin();
    final runtime = StructuredAgentRuntime(gateway, chat: chat);
    addTearDown(() async {
      await runtime.dispose();
      await root.delete(recursive: true);
    });
    final result = runtime.send(
      AgentSession(id: 'progress', owner: 'guest', workspace: root.path),
      'Explain the result',
      const RoomSettings(model: 'fixture'),
      events.add,
    );
    chat.stream.add('{"type":"final","text":"已检查');
    await Future<void>.delayed(Duration.zero);
    final first = events.lastWhere((e) => e.type == 'assistant');
    expect(first.text, '已检查');
    expect(first.data['streaming'], true);
    chat.stream.add('，没有修改文件。"}');
    await chat.stream.close();
    await result;
    final last = events.lastWhere((e) => e.type == 'assistant');
    expect(last.id, first.id);
    expect(last.text, '已检查，没有修改文件。');
    expect(last.data['streaming'], false);
    expect(gateway.calls, 0);
  });

  test('partial public tool update streams but cancel prevents execution of its incomplete action', () async {
    final root = await Directory.systemTemp.createTemp('agent-progress-');
    final events = <AgentEvent>[];
    final chat = _ControlledChat();
    final gateway = ToolGateway(
      workspace: root.path,
      approve: (_) async => false,
      emit: events.add,
      commandRunner: SandboxCommandRunner('missing'),
    )..begin();
    final runtime = StructuredAgentRuntime(gateway, chat: chat);
    addTearDown(() async {
      await runtime.dispose();
      await root.delete(recursive: true);
    });
    final result = runtime.send(
      AgentSession(id: 'progress', owner: 'guest', workspace: root.path),
      'Write a file',
      const RoomSettings(model: 'fixture'),
      events.add,
    );
    final stopped = expectLater(result, throwsA(isA<ApiFailure>()));
    chat.stream.add(
      '{"type":"tool","commentary":"我会先检查现有文件。",'
      '"name":"fs_write","arguments":{"path":"never.txt","content":"partial',
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.lastWhere((e) => e.type == 'commentary').text, '我会先检查现有文件。');
    expect(gateway.calls, 0);
    await runtime.cancel();
    await stopped;
    expect(await File('${root.path}/never.txt').exists(), false);
  });

  test(
    'native bridge streams visible text and private activity before upstream completion',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final root = await Directory.systemTemp.createTemp('agent-stream-');
      final release = Completer<void>(), requestSeen = Completer<void>();
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final activity = <AgentEvent>[];
      upstream.listen((request) async {
        final input =
            jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(input['stream'], true);
        request.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        request.response.bufferOutput = false;
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'reasoning_content': 'private provider state'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': '开始检查'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        await request.response.flush();
        requestSeen.complete();
        await release.future;
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': '，已完成。'},
                'finish_reason': 'stop',
              },
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final gateway = ToolGateway(
        workspace: root.path,
        approve: (_) async => false,
        emit: (_) {},
        commandRunner: SandboxCommandRunner('missing'),
      )..begin();
      final provider = AgentProviderBridge(
        RoomSettings(
          model: 'deepseek-reasoner',
          llmUrl: 'http://127.0.0.1:${upstream.port}/chat/completions',
        ),
      )..onProgress = activity.add;
      final bridge = AgentBridge(gateway, provider);
      await bridge.start();
      final client = http.Client();
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        client.close();
        await bridge.dispose();
        await upstream.close(force: true);
        await root.delete(recursive: true);
      });
      final response = await client.send(
        http.Request('POST', bridge.uri.resolve('/model/v1/chat/completions'))
          ..headers.addAll({
            'Authorization': 'Bearer ${bridge.token}',
            'Content-Type': 'application/json',
          })
          ..body = jsonEncode({
            'stream': true,
            'messages': [
              {'role': 'user', 'content': 'check'},
            ],
          }),
      );
      await requestSeen.future;
      final firstText = Completer<void>();
      final chunks = <Map<String, dynamic>>[];
      final subscription = decodeAgentSse(response.stream).listen((chunk) {
        chunks.add(chunk);
        if ((chunk['choices'] as List? ?? []).isNotEmpty &&
            chunk['choices'][0]['delta']?['content'] == '开始检查' &&
            !firstText.isCompleted) {
          firstText.complete();
        }
      });
      await firstText.future.timeout(const Duration(seconds: 3));
      expect(release.isCompleted, false);
      expect(activity.any((e) => e.data['phase'] == 'reasoning'), true);
      expect(
        activity.every((e) => !e.text.contains('private provider state')),
        true,
      );
      release.complete();
      await subscription.asFuture<void>();
      expect(chunks.last['agentStreamDone'], true);
      expect(jsonEncode(chunks), isNot(contains('private provider state')));
    }, _RealHttpOverrides()),
  );

  for (final width in [360.0, 390.0, 768.0, 1280.0, 1920.0]) {
    for (final language in ['zh', 'ja', 'en']) {
      testWidgets(
        'Agent task timeline at $width $language has concise tools, live progress and Markdown',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final store = MemoryStorage();
          final room = RoomController(
            storage: store,
            chat: FakeChat(),
            site: FakeSite(),
            voice: SilentVoice(),
          );
          await room.initialize();
          final agent = DesktopAgentController(room);
          final locale = LocaleController(store);
          await locale.setLanguage(language);
          agent.workspace = '/workspace';
          agent.session = AgentSession(
            id: 'ui',
            owner: agent.owner,
            workspace: agent.workspace,
          );
          agent.busy = true;
          agent.status = 'OpenCode';
          agent.emit(AgentEvent('user', '检查 README 并说明结果'));
          agent.emit(AgentEvent('commentary', '我会先查看说明文件，再检查相关配置。'));
          agent.emit(
            AgentEvent(
              'toolStart',
              'fs_read',
              id: 'read',
              data: {
                'arguments': {'path': 'README.md'},
              },
            ),
          );
          agent.emit(
            AgentEvent(
              'toolResult',
              'fs_read',
              id: 'read',
              data: {
                'result': {'content': 'PRIVATE_TOOL_PAYLOAD'},
                'state': 'completed',
              },
            ),
          );
          agent.emit(
            AgentEvent(
              'assistant',
              '**已检查** README。\n\n- 未修改文件。',
              id: 'answer',
              data: {'streaming': true},
            ),
          );
          agent.emit(AgentEvent('modelProgress', '正在生成回复'));
          final picture = GlobalKey();
          await tester.pumpWidget(
            SiteLocaleScope(
              controller: locale,
              child: MaterialApp(
                theme: width < 500 ? ThemeData.dark() : ThemeData.light(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width == 360 ? 1.6 : 1),
                  ),
                  child: child!,
                ),
                home: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(16),
                    child: RepaintBoundary(
                      key: picture,
                      child: Material(
                        color:
                            (width < 500 ? ThemeData.dark() : ThemeData.light())
                                .scaffoldBackgroundColor,
                        child: AgentPanel(controller: agent, onGo: (_) {}),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byKey(const Key('agent-progress')), findsOneWidget);
          expect(find.textContaining('README.md'), findsOneWidget);
          expect(find.textContaining('PRIVATE_TOOL_PAYLOAD'), findsNothing);
          expect(find.text('fs_read'), findsNothing);
          expect(tester.takeException(), isNull);
          if (capture && Platform.isMacOS && language == 'zh') {
            await tester.runAsync(() async {
              final boundary =
                  picture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final directory = Directory('artifacts/agent-progress')
                ..createSync(recursive: true);
              await File('${directory.path}/agent-${width.toInt()}.png')
                  .writeAsBytes(png!.buffer.asUint8List());
              image.dispose();
            });
          }
          agent.busy = false;
          agent.emit(
            AgentEvent(
              'assistant',
              '**已检查** README。\n\n- 未修改文件。',
              id: 'answer',
              data: {'streaming': false},
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('agent-progress')), findsNothing);
          await tester.pumpWidget(const SizedBox());
          await agent.shutdown();
          agent.dispose();
          locale.dispose();
          room.dispose();
        },
      );
    }
  }
}
