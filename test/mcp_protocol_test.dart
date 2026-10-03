import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/room_tools.dart';

RoomSettings settings({
  String transport = 'streamable-http',
  String header = 'Authorization',
}) => RoomSettings(
  mcpKey: 'PRIVATE_MCP_KEY',
  apiKey: 'PRIVATE_MODEL_KEY',
  options: {
    'mcpEnabled': true,
    'mcpEndpoint': 'https://tools.example/mcp',
    'mcpTransport': transport,
    'mcpAuthHeader': header,
  },
);
http.Response rpc(
  http.Request req,
  dynamic result, {
  int? id,
  bool sse = false,
}) {
  final data = {
    'jsonrpc': '2.0',
    'id': id ?? jsonDecode(req.body)['id'],
    'result': result,
  };
  return http.Response(
    sse
        ? ': ping\r\n\r\nevent: message\r\ndata: ${jsonEncode(data)}\r\n\r\n'
        : jsonEncode(data),
    200,
    headers: {
      'content-type': sse
          ? 'text/event-stream; charset=utf-8'
          : 'application/json',
    },
  );
}

void main() {
  for (final version in RoomTools.versions) {
    for (final sse in [false, true]) {
      test(
        'MCP $version ${sse ? 'SSE' : 'JSON'} handshake, pairing, isolated auth and cleanup',
        () async {
          final requests = <http.Request>[];
          final tools = RoomTools(
            clientFactory: () => MockClient((req) async {
              requests.add(req);
              expect(req.followRedirects, false);
              expect(req.headers['cookie'], isNull);
              expect(req.headers['authorization'], 'Bearer PRIVATE_MCP_KEY');
              expect(req.body, isNot(contains('PRIVATE_MODEL_KEY')));
              if (req.method == 'DELETE') {
                expect(req.headers['mcp-session-id'], 'session-one');
                return http.Response('', 204);
              }
              final body = jsonDecode(req.body);
              if (body['method'] == 'initialize') {
                expect(body['params']['capabilities'], isEmpty);
                expect(
                  req.headers['mcp-protocol-version'],
                  RoomTools.versions.first,
                );
                final result = rpc(req, {
                  'protocolVersion': version,
                  'capabilities': {'tools': {}},
                }, sse: sse);
                return http.Response(
                  result.body,
                  200,
                  headers: {...result.headers, 'mcp-session-id': 'session-one'},
                );
              }
              expect(req.headers['mcp-session-id'], 'session-one');
              expect(req.headers['mcp-protocol-version'], version);
              if (body['method'] == 'notifications/initialized') {
                return http.Response('', 202);
              }
              expect(body['method'], 'tools/call');
              expect(body['params']['meta'], isNull);
              return rpc(req, {
                'content': [
                  {'type': 'text', 'text': '月读空间 PRIVATE_MCP_KEY'},
                ],
              }, sse: sse);
            }),
          );
          final result = await tools.tool(settings(), 'web_search', {
            'query': '月读',
          }, cookie: 'SITE_COOKIE_PRIVATE');
          expect(result, '月读空间 [redacted]');
          expect(requests.map((r) => r.method), [
            'POST',
            'POST',
            'POST',
            'DELETE',
          ]);
        },
      );
    }
  }
  test(
    'REST retains metadata and site CSRF/cookie only for the explicit bridge',
    () async {
      final requests = <http.Request>[];
      final tools = RoomTools(
        clientFactory: () => MockClient((req) async {
          requests.add(req);
          expect(
            jsonDecode(req.body)['params']['meta']['auth']['api_key'],
            'PRIVATE_MCP_KEY',
          );
          return rpc(req, {'tools': []});
        }),
      );
      await tools.call(
        settings(transport: 'rest'),
        'tools/list',
        cookie: 'SITE_COOKIE_PRIVATE',
      );
      expect(requests.single.headers['cookie'], isNull);
      final s = settings(transport: 'rest');
      await tools.call(
        s.copyWith(
          options: {...s.options, 'mcpEndpoint': '/api/mcp/token-plan'},
        ),
        'tools/list',
        cookie: 'SITE_COOKIE_PRIVATE',
      );
      expect(requests.last.headers['cookie'], 'SITE_COOKIE_PRIVATE');
      expect(requests.last.headers['origin'], endpointUri(s.siteUrl).origin);
      expect(requests.last.headers['authorization'], isNull);
    },
  );
  for (final fault in [
    'version',
    'session',
    'notification',
    'id',
    'rpc',
    'isError',
    'redirect',
    'server-request',
    'missing-result',
  ]) {
    test('MCP rejects $fault without retrying a tool or exposing remote errors', () async {
      var executions = 0;
      final tools = RoomTools(
        clientFactory: () => MockClient((req) async {
          if (req.method == 'DELETE') return http.Response('', 204);
          final body = jsonDecode(req.body);
          if (body['method'] == 'initialize') {
            if (fault == 'redirect') {
              return http.Response(
                '',
                302,
                headers: {'location': 'https://other.example'},
              );
            }
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': {
                  'protocolVersion': fault == 'version'
                      ? '1900-01-01'
                      : RoomTools.versions.first,
                },
              }),
              200,
              headers: {
                'content-type': 'application/json',
                'mcp-session-id': fault == 'session' ? 'bad session' : 'one',
              },
            );
          }
          if (body['method'] == 'notifications/initialized') {
            return http.Response('', fault == 'notification' ? 200 : 202);
          }
          executions++;
          if (fault == 'id') return rpc(req, {}, id: -1);
          if (fault == 'rpc') {
            return http.Response(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': body['id'],
                'error': {
                  'code': -32000,
                  'message': 'PRIVATE_MCP_KEY credential dump',
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (fault == 'missing-result') {
            return http.Response(
              jsonEncode({'jsonrpc': '2.0', 'id': body['id']}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (fault == 'server-request') {
            return http.Response(
              'data: ${jsonEncode({'jsonrpc': '2.0', 'id': 'sample', 'method': 'sampling/createMessage'})}\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return rpc(req, {
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'PRIVATE_MCP_KEY secret'},
            ],
          });
        }),
      );
      try {
        await tools.call(
          settings(),
          'tools/call',
          params: {'name': 'web_search'},
        );
        fail('Fault must be rejected');
      } on ApiFailure catch (error) {
        expect(error.message, isNot(contains('PRIVATE_MCP_KEY')));
      }
      expect(executions, lessThanOrEqualTo(1));
    });
  }
  for (final header in [
    'Cookie',
    'Origin',
    'Host',
    'Referer',
    'MCP-Session-Id',
    'MCP-Protocol-Version',
    'Content-Type',
    'Accept',
  ]) {
    test('MCP denies reserved authentication header $header', () async {
      var called = false;
      final tools = RoomTools(
        clientFactory: () => MockClient((req) async {
          called = true;
          return rpc(req, {});
        }),
      );
      await expectLater(
        tools.call(settings(header: header), 'tools/list'),
        throwsA(isA<ApiFailure>()),
      );
      expect(called, false);
    });
  }
  test('whole-operation timeout covers a stalled response body', () async {
    final body = StreamController<List<int>>();
    final tools = RoomTools(
      timeout: const Duration(milliseconds: 40),
      clientFactory: () => MockClient.streaming(
        (req, bytes) async => http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    await expectLater(
      tools.call(settings(transport: 'rest'), 'tools/list'),
      throwsA(
        isA<ApiFailure>().having((e) => e.message, 'timeout', contains('超时')),
      ),
    );
    await body.close();
  });
  test(
    'cancel interrupts pending initialize and never starts a tool',
    () async {
      final begun = Completer<void>(), body = StreamController<List<int>>();
      var calls = 0;
      final tools = RoomTools(
        clientFactory: () => MockClient.streaming((req, bytes) async {
          calls++;
          begun.complete();
          return http.StreamedResponse(
            body.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final result = expectLater(
        tools.call(settings(), 'tools/call'),
        throwsA(
          isA<ApiFailure>().having((e) => e.message, 'cancel', contains('取消')),
        ),
      );
      await begun.future;
      tools.cancel();
      await result;
      expect(calls, 1);
      await body.close();
    },
  );
  test(
    'oversized streaming RPC is bounded and tools/call is never replayed',
    () async {
      var calls = 0;
      final tools = RoomTools(
        clientFactory: () => MockClient((req) async {
          calls++;
          return http.Response(
            'data: ${'月' * 90000}',
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        }),
      );
      await expectLater(
        tools.call(settings(transport: 'rest'), 'tools/call'),
        throwsA(isA<ApiFailure>()),
      );
      expect(calls, 1);
    },
  );
}
