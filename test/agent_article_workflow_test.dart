import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_tools.dart';
import 'package:tsukuyomi_space_app/core/agent/agent_types.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/agent/desktop_agent_controller.dart';
import 'package:tsukuyomi_space_app/features/agent/native_agent_tools.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';
import 'package:tsukuyomi_space_app/features/site/native_article_editor.dart';

import 'support/fakes.dart';

class AgentSite extends FakeSite implements SiteDataService {
  final writes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(
    String site,
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    if (method == 'POST' && path == '/api/articles') writes.add(Map.of(body!));
    return {
      'success': true,
      'data': path == '/api/user/profile'
          ? {'role': 'user'}
          : path == '/api/article-categories'
          ? [
              {'id': 1, 'name': '其他'},
              {'id': 2, 'name': '公告'},
            ]
          : method == 'POST'
          ? {'id': 42, 'status': 'pending'}
          : [],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalOverrides = HttpOverrides.current;
  setUp(() => HttpOverrides.global = null);
  tearDown(() => HttpOverrides.global = originalOverrides);
  test('Agent edits the active article, detects conflicts, undoes and approves a concrete publish', () async {
    final site = AgentSite(),
        temp = await Directory.systemTemp.createTemp('agent-article-');
    final room = RoomController(
      storage: MemoryStorage(),
      chat: FakeChat(),
      site: site,
      voice: SilentVoice(),
    );
    await room.initialize();
    await room.login('alice', 'password');
    final editor = NativeArticleEditor(room, '/editor');
    await editor.initialize();
    editor.change('title', '手动标题');
    editor.change('content', '手动正文');
    final tools = NativeAgentTools(room);
    final approvals = <AgentApproval>[];
    var allow = false;
    final gateway = ToolGateway(
      workspace: temp.path,
      approve: (request) async {
        approvals.add(request);
        return allow;
      },
      emit: (_) {},
      commandRunner: SandboxCommandRunner('missing'),
      additional: await tools.discover(),
    );
    tools.gateway = gateway;
    gateway.begin();
    final read = await gateway.call('article_read', {});
    editor.change('content', '刚刚手动修改');
    await expectLater(
      gateway.call('article_patch', {
        'revision': read['revision'],
        'changes': {'content': '过时修改'},
      }),
      throwsA(isA<ApiFailure>()),
    );
    expect(editor.fields['content'], '刚刚手动修改');
    final updated = await gateway.call('article_patch', {
      'revision': editor.revision,
      'changes': {'content': 'Agent 正文'},
    });
    expect(editor.fields['content'], 'Agent 正文');
    await gateway.call('article_undo', {});
    expect(editor.fields['content'], '刚刚手动修改');
    final publish = await gateway.call('article_publish', {
      'revision': editor.revision,
    });
    expect(publish['declined'], true);
    expect(site.writes, isEmpty);
    expect(approvals.single.arguments['preview']['content'], '刚刚手动修改');
    allow = true;
    await gateway.call('article_publish', {'revision': editor.revision});
    expect(site.writes.single['content'], '刚刚手动修改');
    expect(updated['revision'], isA<String>());
    gateway.cancel();
    tools.dispose();
    editor.dispose();
    room.dispose();
    await temp.delete(recursive: true);
  });

  test('account/site changes invalidate Agent session and restore only its owner workspace', () async {
    final store = MemoryStorage();
    final room = RoomController(
      storage: store,
      chat: FakeChat(),
      site: FakeSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    final agent = DesktopAgentController(room);
    final temp = await Directory.systemTemp.createTemp('agent-identity-');
    await agent.selectWorkspace(temp.path);
    final guest = agent.session!;
    agent.emit(AgentEvent('assistant', '访客任务'));
    await agent.stop();
    await room.login('alice', 'password');
    for (var i = 0; agent.busy && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(agent.session, isNull);
    expect(agent.workspace, isEmpty);
    await agent.selectWorkspace(temp.path);
    expect(agent.session!.owner, isNot(guest.owner));
    expect(agent.session!.events, isEmpty);
    await room.logout();
    for (var i = 0; (agent.busy || agent.session == null) && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(agent.session!.owner, guest.owner);
    expect(agent.session!.events.single.text, '访客任务');
    agent.dispose();
    room.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'upload approval shows an immutable content snapshot and checksum',
    () async {
      final temp = await Directory.systemTemp.createTemp('agent-preview-');
      final source = File('${temp.path}/note.txt');
      await source.writeAsString('将上传的正文');
      final room = RoomController(
        storage: MemoryStorage(),
        chat: FakeChat(),
        site: AgentSite(),
        voice: SilentVoice(),
      );
      await room.initialize();
      await room.login('alice', 'password');
      final tools = NativeAgentTools(room);
      AgentApproval? asked;
      final gateway = ToolGateway(
        workspace: temp.path,
        approve: (request) async {
          asked = request;
          await source.writeAsString('确认时已改变的原文件');
          return false;
        },
        emit: (_) {},
        commandRunner: SandboxCommandRunner('missing'),
        additional: await tools.discover(),
      );
      tools.gateway = gateway;
      gateway.begin();
      final result = await gateway.call('attachment_upload', {
        'path': 'note.txt',
      });
      expect(result['declined'], true);
      expect(asked!.arguments['preview'], '将上传的正文');
      expect(
        asked!.arguments['sha256'],
        sha256.convert(utf8.encode('将上传的正文')).toString(),
      );
      expect(
        await File(asked!.arguments['previewPath'] as String).readAsString(),
        '将上传的正文',
      );
      gateway.cancel();
      tools.dispose();
      room.dispose();
      await temp.delete(recursive: true);
    },
  );

  test('MCP discovery preserves allowlist and requires approval even with readOnlyHint', () async {
    var executions = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(request.headers.value('Authorization'), 'Bearer private-key');
      if (body['method'] == 'tools/call') executions++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'result': body['method'] == 'tools/list'
              ? {
                  'tools': [
                    for (final name in ['allowed', 'excluded'])
                      {
                        'name': name,
                        'annotations': {'readOnlyHint': true},
                        'inputSchema': {
                          'type': 'object',
                          'properties': {
                            'query': {'type': 'string'},
                          },
                          'required': ['query'],
                        },
                      },
                  ],
                }
              : {
                  'content': [
                    {'type': 'text', 'text': 'result private-key'},
                  ],
                },
        }),
      );
      await request.response.close();
    });
    final temp = await Directory.systemTemp.createTemp('agent-mcp-');
    final store = MemoryStorage()
      ..value = RoomSettings(
        model: 'fixture',
        mcpKey: 'private-key',
        options: {
          'mcpEnabled': true,
          'mcpEndpoint': 'http://127.0.0.1:${server.port}/mcp',
          'mcpAllowlist': 'allowed',
        },
      );
    final room = RoomController(
      storage: store,
      chat: FakeChat(),
      site: AgentSite(),
      voice: SilentVoice(),
    );
    await room.initialize();
    final tools = NativeAgentTools(room);
    var allow = false;
    final gateway = ToolGateway(
      workspace: temp.path,
      approve: (_) async => allow,
      emit: (_) {},
      commandRunner: SandboxCommandRunner('missing'),
      additional: await tools.discover(),
    );
    tools.gateway = gateway;
    gateway.begin();
    expect(gateway.tools.containsKey('mcp_excluded'), false);
    expect(
      (await gateway.call('mcp_allowed', {'query': 'read'}))['declined'],
      true,
    );
    expect(executions, 0);
    allow = true;
    expect(
      await gateway.call('mcp_allowed', {'query': 'read'}),
      'result [redacted]',
    );
    expect(executions, 1);
    gateway.cancel();
    tools.dispose();
    room.dispose();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });
}
