import 'support/site_fixture.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/features/room/room_controller.dart';

import 'support/fakes.dart';

void main() {
  for (final protocol in ['openai', 'responses', 'anthropic']) {
    test(
      'native Room → current real website proxy → $protocol → MCP → one visible saved turn',
      () async {
        final mcp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var executions = 0;
        final methods = <String>[];
        mcp.listen((req) async {
          if (req.method == 'DELETE') {
            req.response.statusCode = 204;
            await req.response.close();
            return;
          }
          final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
          methods.add(body['method'] as String);
          if (body['method'] == 'notifications/initialized') {
            req.response.statusCode = 202;
            await req.response.close();
            return;
          }
          final result = body['method'] == 'initialize'
              ? {
                  'protocolVersion': '2025-11-25',
                  'capabilities': {'tools': {}},
                }
              : {
                  'content': [
                    {'type': 'text', 'text': '原生 MCP 参考资料'},
                  ],
                };
          if (body['method'] == 'tools/call') {
            executions++;
            expect(body['params']['name'], 'web_search');
            expect(body['params']['arguments'], {'query': '月读空间'});
          }
          expect(req.headers.value('cookie'), isNull);
          req.response.headers.contentType = ContentType.json;
          req.response.headers.set('MCP-Session-Id', 'native-proxy');
          req.response.write(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}),
          );
          await req.response.close();
        });
        final storage = MemoryStorage()
          ..value = RoomSettings(
            siteUrl: siteFixtureOrigin,
            llmUrl: {
              'openai': 'https://api.deepseek.com/chat/completions',
              'responses': 'https://api.openai.com/v1/responses',
              'anthropic': 'https://api.anthropic.com/v1/messages',
            }[protocol]!,
            model: 'native-protocol-fixture-$protocol',
            apiKey: 'native-fixture-key',
            options: {
              'llmProxy': true,
              'mcpEnabled': true,
              'mcpEndpoint': 'http://127.0.0.1:${mcp.port}/mcp',
              'mcpTransport': 'streamable-http',
              'memoryEnabled': false,
            },
          );
        final site = SiteClient(), chat = LlmClient();
        final room = RoomController(
          storage: storage,
          site: site,
          chat: chat,
          voice: SilentVoice(),
        );
        addTearDown(() async {
          room.dispose();
          await mcp.close(force: true);
        });
        await room.initialize();
        await room.login('e2e-user', 'e2e-password');
        await room.startConversation(clearHistory: true);
        final seen = <String>[];
        room.streamRevision.addListener(() {
          if (room.partial.isNotEmpty) seen.add(room.partial);
        });
        await room.send('核对这条资料');
        expect(room.error, isEmpty);
        expect(room.turns.single.assistant, contains('资料核对完成。'));
        expect(chat.lastAgentRounds, 2);
        expect(executions, 1);
        expect(methods, [
          'initialize',
          'notifications/initialized',
          'tools/call',
        ]);
        final history = await site.history(storage.value.siteUrl);
        expect(history.single.assistant, room.turns.single.assistant);
        expect(
          jsonEncode(history.map((t) => t.toJson()).toList()),
          isNot(contains('NATIVE_PROTOCOL_OPAQUE')),
        );
        expect(room.turns.single.assistant, isNot(contains('site_read1')));
        expect(seen.any((text) => text.contains('先查看资料。')), true);
      },
      skip: !const bool.fromEnvironment('RUN_WEBSITE_INTEGRATION'),
    );
  }
}
