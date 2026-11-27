import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'model_protocol.dart';
import 'model_runtime.dart';
import 'room_protocol.dart';
import 'official_api.dart';

/// Website shared/deepseek-chat.cjs, application contract 2026-11-13.
class Deepseek {
  static bool supported(RoomSettings s) {
    final uri = Uri.tryParse(s.llmUrl);
    return !s.demo &&
        uri != null &&
        (!s.usesOfficialApi || s.flag('officialApps', true)) &&
        RegExp(r'^deepseek-(?:flash|v4(?:\.1)?-flash)(?:-|$)')
            .hasMatch(s.model) &&
        (uri.host == 'api.deepseek.com' ||
            s.usesOfficialApi ||
            s.flag('deepseekApps'));
  }

  static Uri endpoint(RoomSettings s, [String path = '/chat/completions']) {
    final uri = roomChatEndpoint(s.llmUrl);
    if (s.usesOfficialApi) {
      return endpointUri(s.siteUrl).resolve('/official-api/v1/deepseek$path');
    }
    final prefix = uri.host == 'api.deepseek.com'
        ? ''
        : uri.path
              .replaceFirst(
                RegExp(
                  r'/(?:anthropic/v1/messages|chat/completions|responses)/?$',
                ),
                '',
              )
              .replaceFirst(RegExp(r'/$'), '');
    final suffix = prefix.endsWith('/v1') && path.startsWith('/v1/')
        ? path.substring(3)
        : path;
    return uri.replace(path: '$prefix$suffix', query: null, fragment: null);
  }

  static Map<String, dynamic>? metadata(dynamic raw) {
    if (raw is! Map || raw['provider'] != 'deepseek') return null;
    modelBound(raw, 512000);
    final files = (raw['files'] as List? ?? [])
        .whereType<Map>()
        .where(
          (f) => RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch('${f['id'] ?? ''}'),
        )
        .take(20)
        .map(
          (f) => <String, dynamic>{
            'id': f['id'],
            'name': _clip('${f['name'] ?? '文件'}', 200),
            'size': f['size'] is num
                ? (f['size'] as num).clamp(0, 100 * 1024 * 1024)
                : 0,
            'purpose': _clip('${f['purpose'] ?? 'user_data'}', 30),
          },
        )
        .toList();
    return {
      'provider': 'deepseek',
      'endpoint': _clip('${raw['endpoint'] ?? ''}', 500),
      'files': files,
      'server_tool_calls': (raw['server_tool_calls'] as List? ?? [])
          .take(128)
          .toList(),
      'annotations': (raw['annotations'] as List? ?? []).take(100).toList(),
      'title': _clip('${raw['title'] ?? ''}', 160),
      'truncated': raw['truncated'] == true,
    };
  }

  static String _clip(String s, int n) => s.substring(0, s.length.clamp(0, n));
  static List<Map<String, String>> sources(Map? meta) {
    final links = <String, String>{};
    for (final a in (meta?['annotations'] as List? ?? []).whereType<Map>()) {
      final c = a['url_citation'] is Map ? a['url_citation'] as Map : a;
      final uri = Uri.tryParse('${c['url'] ?? ''}');
      if (uri != null &&
          ['https', 'http'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty) {
        links[uri.toString()] = _clip('${c['title'] ?? uri}', 240);
      }
    }
    return links.entries.map((e) => {'url': e.key, 'title': e.value}).toList();
  }

  static Map<String, dynamic> body(
    RoomSettings s,
    String system,
    List<Map<String, dynamic>> conversation,
    String message, {
    List<Map<String, dynamic>> files = const [],
    Map<String, dynamic>? image,
  }) {
    final target = endpoint(s).toString();
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': system},
    ];
    for (final item in conversation) {
      final saved = metadata(item['deepseek']);
      final previous = <String, dynamic>{
        'role': item['role'],
        'content': item['content'],
      };
      if (saved?['endpoint'] == target) {
        if (item['role'] == 'user' && (saved!['files'] as List).isNotEmpty) {
          previous['content'] = [
            for (final f in saved['files'])
              {'type': 'file', 'file_id': f['id']},
            {'type': 'text', 'text': item['content']},
          ];
        }
        if (item['role'] == 'assistant' &&
            (saved!['server_tool_calls'] as List).isNotEmpty) {
          previous['server_tool_calls'] = saved['server_tool_calls'];
        }
      }
      messages.add(previous);
    }
    if (files.length > 5) throw const ApiFailure('每次最多附加 5 个文件');
    for (final file in files) {
      if (file['endpoint'] != target ||
          !RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch('${file['id']}')) {
        throw const ApiFailure('附件属于其他模型连接，请重新上传');
      }
    }
    final content = [
      for (final f in files) {'type': 'file', 'file_id': f['id']},
      if (image?['dataUrl'] != null)
        {
          'type': 'image_url',
          'image_url': {'url': image!['dataUrl']},
        },
      {'type': 'text', 'text': message},
    ];
    messages.add({
      'role': 'user',
      'content': content.length == 1 ? message : content,
    });
    return {
      'model': Uri.parse(s.llmUrl).host == 'api.deepseek.com'
          ? 'deepseek-flash'
          : s.model,
      'messages': messages,
      'max_tokens':
          ModelRuntime(s).resolveParameters()['maxOutputTokens']['value'] ??
          4096,
      'stream': true,
      'stream_options': {'include_usage': true},
      'thinking': {'type': s.flag('deepseekThinking') ? 'enabled' : 'disabled'},
      'safety_check': {'level': 'high'},
      'title': {'enabled': true},
    };
  }

  static List<Map<String, dynamic>> serverTools(RoomSettings s) => [
    if (s.flag('deepseekSearch')) {'type': 'deepseek_web_search'},
    if (s.flag('deepseekReadUrl', true)) {'type': 'deepseek_read_url'},
  ];
}

/// Owns one request; cancellation closes the transport, with no paid retries.
class DeepseekClient {
  DeepseekClient({http.Client Function()? clientFactory})
    : _factory = clientFactory ?? http.Client.new;
  final http.Client Function() _factory;
  http.Client? _active;
  void cancel() {
    _active?.close();
    _active = null;
  }

  Future<Map<String, dynamic>> upload(
    RoomSettings settings,
    String path,
    List<int> bytes,
    String name,
    String mime, {
    String? purpose,
    String? cookie,
    String? accountId,
  }) async {
    cancel();
    if (!Deepseek.supported(settings)) {
      throw const ApiFailure('当前模型不支持 DeepSeek 应用接口');
    }
    final official = settings.usesOfficialApi,
        proxy = !settings.usesOfficialApi && settings.flag('llmProxy');
    final limit = official || proxy || path.contains('/asr')
        ? 8 * 1024 * 1024
        : 100 * 1024 * 1024;
    if (bytes.isEmpty || bytes.length > limit) {
      throw ApiFailure('文件应为 1 字节至 ${limit ~/ (1024 * 1024)} MB');
    }
    if (proxy && Uri.parse(settings.llmUrl).host != 'api.deepseek.com') {
      throw const ApiFailure('自定义网关请关闭代理并使用直连');
    }
    final client = _factory();
    _active = client;
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      var uri = Deepseek.endpoint(settings, path);
      if (official) {
        if (cookie == null || accountId == null) {
          throw const ApiFailure('请先登录月读空间');
        }
        final preflight =
            http.Request(
                'GET',
                endpointUri(settings.siteUrl)
                    .resolve('/official-api/api/dashboard'),
              )
              ..followRedirects = false
              ..headers.addAll({
                'Cookie': cookie,
                'Origin': endpointUri(settings.siteUrl).origin,
              });
        final data = await _json(
          await client.send(preflight).timeout(const Duration(seconds: 15)),
        );
        final dashboard = officialDashboard(data, accountId);
        officialRoomSettings(settings, dashboard);
        headers.addAll({
          'Cookie': cookie,
          'Origin': endpointUri(settings.siteUrl).origin,
          'X-Official-Expected-Account':
              '${(dashboard['me'] as Map)['account_id']}',
          'Idempotency-Key': newTurnId(),
        });
      } else {
        if (settings.apiKey.isEmpty ||
            settings.apiKey == 'tsukuyomi-site-session') {
          throw const ApiFailure('请先填写自己的 DeepSeek API Key');
        }
        if (proxy) {
          uri = endpointUri(settings.siteUrl)
              .resolve('/api/chat/deepseek$path');
          headers.addAll({
            'X-Deepseek-Key': settings.apiKey,
            'Origin': endpointUri(settings.siteUrl).origin,
            'Cookie': ?cookie,
          });
        } else {
          headers['Authorization'] = 'Bearer ${settings.apiKey}';
        }
      }
      final http.BaseRequest request;
      if (official || proxy) {
        request = http.Request('POST', uri)
          ..body = jsonEncode({
            'file': {'name': name, 'type': mime, 'data': base64Encode(bytes)},
            'purpose': ?purpose,
          });
        headers['Content-Type'] = 'application/json';
      } else {
        request = http.MultipartRequest('POST', uri)
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: name),
          );
        if (purpose != null) {
          (request as http.MultipartRequest).fields['purpose'] = purpose;
        }
      }
      request.followRedirects = false;
      request.headers.addAll(headers);
      return await _json(
        await client.send(request).timeout(const Duration(seconds: 120)),
      );
    } finally {
      if (identical(_active, client)) _active = null;
      client.close();
    }
  }

  static Future<Map<String, dynamic>> _json(
    http.StreamedResponse response,
  ) async {
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 120),
    )) {
      bytes.addAll(part);
      if (bytes.length > 4 * 1024 * 1024) throw const ApiFailure('接口响应过大');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map) throw const ApiFailure('接口返回格式无效');
    if ((response.statusCode < 200 || response.statusCode >= 300) ||
        data['error'] != null) {
      throw ApiFailure(
        '${data['error'] is Map ? data['error']['message'] : data['message'] ?? 'DeepSeek 请求失败'}',
        status: response.statusCode,
      );
    }
    return Map<String, dynamic>.from(data);
  }
}

class DeepseekReply {
  DeepseekReply(this.target);
  final String target;
  String reasoning = '', title = '', finish = '';
  Map<String, dynamic>? metadata;
  final events = <String, Map>{};
  final _calls = <int, Map<String, String>>{};
  final _text = StringBuffer();
  Map<String, dynamic> usage = {};
  Map<String, dynamic> _meta = {};
  String consume(Map data) {
    if (data['error'] != null) throw const ApiFailure('DeepSeek 未完成回复');
    if (data['usage'] is Map) usage = Map<String, dynamic>.from(data['usage']);
    final choices = (data['choices'] as List? ?? []).whereType<Map>();
    final choice = choices.where((c) => (c['index'] ?? 0) == 0).firstOrNull;
    if (choice == null) return '';
    final delta = (choice['delta'] ?? choice['message'] ?? {}) as Map;
    if (choice['finish_reason'] == 'content_filter') {
      reasoning = '';
      metadata = null;
      throw const ApiFailure('这次内容未通过模型安全检查，请换个说法再试');
    }
    final text = delta['content'] is String ? delta['content'] as String : '';
    _text.write(text);
    if (_text.length > 524288) throw const ApiFailure('模型回复过长');
    reasoning += delta['reasoning_content'] as String? ?? '';
    if (reasoning.length > 524288) throw const ApiFailure('模型思考过长');
    for (final c in (delta['tool_calls'] as List? ?? []).whereType<Map>()) {
      final index = (c['index'] as num? ?? 0).toInt();
      final prior = _calls.putIfAbsent(
        index,
        () => {'id': '', 'name': '', 'arguments': ''},
      );
      if (c['id'] is String) prior['id'] = c['id'];
      final f = c['function'] as Map? ?? {};
      prior['name'] = '${prior['name']}${f['name'] ?? ''}';
      prior['arguments'] = '${prior['arguments']}${f['arguments'] ?? ''}';
      modelBound(prior, 32768);
      if (_calls.length > 6) throw const ApiFailure('工具调用数量超过限制');
    }
    final event = choice['server_tool_event'];
    if (event is Map && event['call'] is Map) {
      events['${event['step']}:${event['call']['index']}'] = event['call'];
    }
    if (events.length > 128) throw const ApiFailure('搜索步骤过多');
    for (final key in ['server_tool_calls', 'annotations', 'title']) {
      if (delta[key] != null) _meta[key] = delta[key];
    }
    if (choice['finish_reason'] != null) finish = '${choice['finish_reason']}';
    if (metadata == null ||
        choice['finish_reason'] != null ||
        delta['server_tool_calls'] != null ||
        delta['annotations'] != null ||
        delta['title'] != null) {
      _meta = Deepseek.metadata({
        ..._meta,
        'provider': 'deepseek',
        'endpoint': target,
        'truncated': finish == 'length',
      })!;
      metadata = _meta;
      title = '${_meta['title']}';
    }
    return text;
  }

  ModelCompletion complete() {
    if (finish.isEmpty || (_text.isEmpty && _calls.isEmpty)) {
      throw const ModelStreamInterrupted('连接中断，回复尚未完成');
    }
    final calls = _calls.values
        .map((c) => ModelCall(c['id']!, c['name']!, c['arguments']!))
        .toList();
    return ModelCompletion(
      reply: _text.toString(),
      calls: calls,
      usage: usage,
      items: [
        {
          'role': 'assistant',
          'content': _text.isEmpty ? null : _text.toString(),
          'reasoning_content': reasoning,
          if (calls.isNotEmpty)
            'tool_calls': calls.map((c) => c.openAi).toList(),
          if ((_meta['server_tool_calls'] as List? ?? []).isNotEmpty)
            'server_tool_calls': _meta['server_tool_calls'],
        },
      ],
    );
  }

  Stream<ModelWireEvent> read(
    http.StreamedResponse response,
    void Function() update,
  ) async* {
    if ((response.headers['content-type'] ?? '').contains('application/json')) {
      final data = await DeepseekClient._json(response);
      final text = consume(data);
      update();
      if (text.isNotEmpty) yield ModelWireEvent('text', text: text);
    } else {
      if (!(response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        throw const ApiFailure('接口没有返回流式对话');
      }
      var done = false;
      await for (final frame in modelFrames(
        response.stream.timeout(const Duration(seconds: 45)),
      )) {
        if (frame.data == '[DONE]') {
          done = true;
          break;
        }
        final text = consume(jsonDecode(frame.data) as Map);
        update();
        if (text.isNotEmpty) yield ModelWireEvent('text', text: text);
      }
      if (!done) throw const ModelStreamInterrupted('连接中断，回复尚未完成');
    }
    yield ModelWireEvent('complete', completion: complete());
  }
}
