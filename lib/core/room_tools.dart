import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'room_archive.dart';

/// Same JSON-RPC REST bridge used by the website. Site cookies never leave the site.
class RoomTools {
  RoomTools({http.Client Function()? clientFactory})
    : _factory = clientFactory ?? http.Client.new;
  final http.Client Function() _factory;
  http.Client? _active;
  void cancel() {
    _active?.close();
    _active = null;
  }

  Future<dynamic> call(
    RoomSettings s,
    String method, {
    Map<String, dynamic> params = const {},
    String? cookie,
  }) async {
    final endpoint = s.option('mcpEndpoint');
    final local = endpoint == '/api/mcp/token-plan';
    final uri = local
        ? endpointUri(s.siteUrl).resolve(endpoint)
        : endpointUri(endpoint);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (local) {
      headers.addAll({
        'Origin': uri.origin,
        'X-Requested-With': 'XMLHttpRequest',
        'Cookie': ?cookie,
      });
    } else {
      final header = s.option('mcpAuthHeader', 'Authorization');
      if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(header) ||
          ['cookie', 'host', 'content-length'].contains(header.toLowerCase())) {
        throw const ApiFailure('MCP 鉴权头无效');
      }
      if (s.mcpKey.isNotEmpty) {
        headers[header] =
            header.toLowerCase() == 'authorization' &&
                !s.mcpKey.startsWith('Bearer ')
            ? 'Bearer ${s.mcpKey}'
            : s.mcpKey;
      }
    }
    final client = _factory();
    _active = client;
    try {
      final req = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll(headers)
        ..body = jsonEncode({
          'jsonrpc': '2.0',
          'id': DateTime.now().millisecondsSinceEpoch,
          'method': method,
          'params': {
            ...params,
            'meta': {
              'auth': {
                'api_key': s.mcpKey,
                'api_host': s.option('mcpApiHost', 'https://api.minimaxi.chat'),
                'base_path': s.option('mcpBasePath'),
                'resource_mode': s.option('mcpResourceMode', 'url'),
              },
            },
          },
        });
      final response = await client
          .send(req)
          .timeout(const Duration(seconds: 8));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 8),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const ApiFailure('MCP 返回内容过大');
        }
      }
      if (response.statusCode != 200) {
        throw providerFailure('MCP', response.statusCode);
      }
      final data = jsonMap(jsonDecode(utf8.decode(bytes)));
      if (data['error'] != null) {
        throw const ApiFailure('MCP 工具调用失败，请检查端点、Key 和工具权限');
      }
      return data['result'] ?? data;
    } finally {
      client.close();
      if (identical(_active, client)) _active = null;
    }
  }

  bool allowed(RoomSettings s, String name) {
    final list = s
        .option('mcpAllowlist')
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty);
    return list.isEmpty || list.contains(name);
  }

  Future<String> tool(
    RoomSettings s,
    String name,
    Map<String, dynamic> args, {
    String? cookie,
  }) async {
    if (!s.flag('mcpEnabled') || !allowed(s, name)) return '';
    final result = await call(
      s,
      'tools/call',
      params: {'name': name, 'arguments': args},
      cookie: cookie,
    );
    if (result is Map && result['isError'] == true) {
      throw const ApiFailure('MCP 工具执行失败');
    }
    final text = result is String
        ? result
        : result is Map && result['content'] is List
        ? jsonRows(result['content']).map((v) => v['text'] ?? '').join('\n')
        : jsonEncode(result);
    return text.substring(0, text.length.clamp(0, 1200));
  }
}
