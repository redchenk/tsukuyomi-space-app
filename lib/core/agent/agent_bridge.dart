import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'agent_tools.dart';
import 'agent_provider.dart';
import '../models.dart';
import 'agent_limits.dart';

class AgentBridge {
  AgentBridge(this.gateway, this.provider);
  final ToolGateway gateway;
  final AgentProviderBridge provider;
  final token = List.generate(
    32,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  HttpServer? _server;
  Uri get uri => Uri.parse('http://127.0.0.1:${_server!.port}');
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_handle(request)));
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.headers.value('Authorization') != 'Bearer $token') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    if (request.method != 'POST') {
      request.response.statusCode = 405;
      await request.response.close();
      return;
    }
    dynamic id;
    var forwardingModel = false;
    try {
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > agentMaxJsonBytes) {
          throw const FormatException('Request too large');
        }
      }
      final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (request.uri.path == '/model/v1/chat/completions') {
        forwardingModel = true;
        await provider.handle(request, body);
        return;
      }
      if (request.uri.path != '/mcp') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      id = body['id'];
      if (id == null) {
        request.response.statusCode = 202;
        await request.response.close();
        return;
      }
      final params = Map<String, dynamic>.from(body['params'] as Map? ?? {});
      final dynamic result = switch (body['method']) {
        'initialize' => {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'tsukuyomi', 'version': '0.6.4'},
        },
        'ping' => {},
        'tools/list' => {
          'tools': gateway.tools.values.map((t) => t.toJson()).toList(),
        },
        'tools/call' => {
          'content': [
            {
              'type': 'text',
              'text': jsonEncode(
                await gateway.call(
                  params['name'] as String,
                  Map<String, dynamic>.from(params['arguments'] as Map? ?? {}),
                ),
              ),
            },
          ],
        },
        _ => throw const FormatException('Unknown MCP method'),
      };
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
    } catch (error) {
      if (request.uri.path.startsWith('/model/')) {
        final status = error is ApiFailure ? error.status : null;
        request.response.statusCode =
            status != null && status >= 400 && status < 600
            ? status
            : error is TimeoutException
            ? 504
            : forwardingModel
            ? 502
            : 400;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'error': {
              'message': error.toString(),
              'type': 'invalid_request_error',
            },
          }),
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': true,
              'content': [
                {'type': 'text', 'text': error.toString()},
              ],
            },
          }),
        );
      }
    } finally {
      try {
        await request.response.close();
      } on SocketException {
        // Cancellation closes both loopback and provider clients.
      } on HttpException {
        // The caller has disconnected and cannot receive a response.
      }
    }
  }

  Future<void> dispose() async {
    provider.cancel();
    await _server?.close(force: true);
    _server = null;
  }
}
