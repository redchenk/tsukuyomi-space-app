import 'dart:convert';

import 'models.dart';

Uri roomChatEndpoint(String value) {
  var uri = endpointUri(value);
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/responses') ||
      path.endsWith('/messages') ||
      path.endsWith('/api/chat') ||
      path.endsWith('/chat/completions')) {
    return uri.replace(path: path);
  }
  if (uri.port == 11434 && (path.isEmpty || path == '/api')) {
    return uri.replace(path: '/api/chat');
  }
  return compatibleEndpoint(value);
}

String roomProtocol(Uri uri) => uri.path.endsWith('/responses')
    ? 'responses'
    : uri.path.endsWith('/messages')
    ? 'anthropic'
    : uri.path.endsWith('/api/chat')
    ? 'ollama'
    : 'openai';
Map<String, String> roomChatHeaders(RoomSettings s, Uri uri) => {
  'Content-Type': 'application/json',
  'Accept': 'text/event-stream',
  if (uri.host == 'api.anthropic.com') ...{
    'anthropic-version': '2023-06-01',
    if (s.apiKey.isNotEmpty) 'x-api-key': s.apiKey,
  } else if (s.apiKey.isNotEmpty)
    'Authorization': 'Bearer ${s.apiKey}',
  if (uri.host == 'openrouter.ai') ...{
    'HTTP-Referer': endpointUri(s.siteUrl).origin,
    'X-OpenRouter-Title': 'Tsukuyomi Space',
  },
};
Map<String, dynamic> roomChatBody(
  RoomSettings s,
  String system,
  List<Map<String, dynamic>> history,
  String text, {
  Map<String, dynamic>? image,
  bool stream = true,
  bool jsonObject = false,
}) {
  final protocol = roomProtocol(roomChatEndpoint(s.llmUrl));
  final dataUrl = image?['dataUrl'] as String?;
  final data = dataUrl?.split(',').last;
  if (text.isEmpty && dataUrl != null) text = '请描述这张图片。';
  final user = <String, dynamic>{'role': 'user', 'content': text};
  if (protocol == 'responses') {
    return {
      'model': s.model,
      'instructions': system,
      'input': [
        ...history,
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': text},
            if (dataUrl != null) {'type': 'input_image', 'image_url': dataUrl},
          ],
        },
      ],
      'stream': stream,
      if (jsonObject)
        'text': {
          'format': {'type': 'json_object'},
        },
    };
  }
  if (protocol == 'ollama') {
    return {
      'model': s.model,
      'stream': stream,
      if (jsonObject) 'format': 'json',
      'options': {'temperature': 0.4},
      'messages': [
        {'role': 'system', 'content': system},
        ...history,
        {
          ...user,
          if (data != null) 'images': [data],
        },
      ],
    };
  }
  if (protocol == 'anthropic') {
    return {
      'model': s.model,
      'system': system,
      'max_tokens': 16384,
      'temperature': 1,
      'stream': stream,
      'messages': [
        ...history,
        {
          ...user,
          if (data != null)
            'content': [
              {'type': 'text', 'text': text},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': image?['type'] ?? 'image/png',
                  'data': data,
                },
              },
            ],
        },
      ],
    };
  }
  return {
    'model': s.model,
    'stream': stream,
    if (jsonObject) 'response_format': {'type': 'json_object'},
    if (RegExp(
      'moonshot|kimi',
      caseSensitive: false,
    ).hasMatch('${s.llmUrl} ${s.model}'))
      'temperature': 1,
    'messages': [
      {'role': 'system', 'content': system},
      ...history,
      {
        ...user,
        if (dataUrl != null)
          'content': [
            {'type': 'text', 'text': text},
            {
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            },
          ],
      },
    ],
  };
}

String payloadText(dynamic p) {
  if (p is! Map) return '';
  for (final key in ['reply', 'output_text', 'response']) {
    if (p[key] is String) return p[key];
  }
  if (p['data'] is Map) return payloadText(p['data']);
  if (p['output'] is List) {
    return (p['output'] as List).map((v) => payloadText(v)).join();
  }
  if (p['content'] is List) {
    return (p['content'] as List)
        .where((v) => ['text', 'output_text'].contains(v['type']))
        .map((v) => v['text'] ?? '')
        .join();
  }
  if (p['choices'] is List) {
    return (p['choices'] as List)
        .where((v) => v['index'] == null || v['index'] == 0)
        .map((v) => v['message']?['content'] ?? v['text'] ?? '')
        .join();
  }
  return p['message']?['content'] as String? ?? '';
}

void validateCompletion(Map p) {
  if (p['error'] != null || p['success'] == false || p['type'] == 'error') {
    throw const ApiFailure('模型服务返回错误，请检查配置');
  }
  final reasons = [
    for (final v in p['choices'] as List? ?? []) v['finish_reason'],
    p['stop_reason'],
    p['delta'] is Map ? p['delta']['stop_reason'] : null,
    p['message'] is Map ? p['message']['stop_reason'] : null,
  ];
  if (reasons.any(
        (v) => [
          'length',
          'max_tokens',
          'content_filter',
          'tool_calls',
          'function_call',
          'tool_use',
        ].contains(v),
      ) ||
      ['response.failed', 'response.incomplete'].contains(p['type']) ||
      ['failed', 'incomplete'].contains(p['status'])) {
    throw const ModelIncompleteFailure('模型回复未完整结束，请重试');
  }
}

/// Byte boundaries, CRLF and UTF-8 are decoded before interpreting protocol events.
Stream<String> decodeRoomStream(
  Stream<List<int>> bytes,
  String protocol, {
  int maxChars = 200000,
  int maxEventChars = 1024 * 1024,
}) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  var completed = false, event = 'message', received = '', size = 0;
  final data = <String>[];
  String consume(String raw) {
    if (raw == '[DONE]') {
      completed = true;
      return '';
    }
    if (raw.trim().isEmpty) return '';
    final p = jsonDecode(raw) as Map;
    validateCompletion(p);
    if (event == 'error') throw const ApiFailure('模型流式请求失败');
    String delta = '', finalText = '';
    switch (protocol) {
      case 'ollama':
        delta = p['message']?['content'] ?? p['response'] ?? '';
        completed = p['done'] == true;
      case 'anthropic':
        if (p['type'] == 'content_block_delta' &&
            p['delta']?['type'] == 'text_delta') {
          delta = p['delta']['text'] ?? '';
        }
        if (p['type'] == 'message_stop') completed = true;
      case 'responses':
        if (p['type'] == 'response.output_text.delta') delta = p['delta'] ?? '';
        if (p['type'] == 'response.completed') {
          validateCompletion(p['response'] as Map? ?? {});
          completed = true;
          finalText = payloadText(p['response']);
        }
      case 'proxy':
        if (event == 'delta') delta = p['text'] ?? '';
        if (event == 'done') {
          completed = true;
          finalText = p['reply'] ?? '';
        }
      default:
        for (final c in p['choices'] as List? ?? []) {
          if (c['index'] != null && c['index'] != 0) continue;
          final value = c['delta']?['content'];
          if (value is String) delta += value;
          if (value is List) {
            delta += value
                .where((v) => v['type'] == 'text')
                .map((v) => v['text'] ?? '')
                .join();
          }
          if (c['finish_reason'] == 'stop') completed = true;
        }
    }
    if (finalText.isNotEmpty && received.isEmpty) delta = finalText;
    received += delta;
    if (received.length > maxChars) throw const ApiFailure('回复过长，请缩短请求');
    return delta;
  }

  await for (final line in lines) {
    if (protocol == 'ollama') {
      if (line.length > maxEventChars) throw const ApiFailure('模型事件过大');
      final delta = consume(line);
      if (delta.isNotEmpty) yield delta;
    } else if (line.isEmpty) {
      if (data.isNotEmpty) {
        final delta = consume(data.join('\n'));
        data.clear();
        size = 0;
        if (delta.isNotEmpty) yield delta;
      }
      event = 'message';
    } else if (line.startsWith('data:')) {
      final v = line.substring(5).trimLeft();
      size += v.length;
      if (size > maxEventChars) throw const ApiFailure('模型事件过大');
      data.add(v);
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    }
    if (completed) return;
  }
  if (data.isNotEmpty) {
    final delta = consume(data.join('\n'));
    if (delta.isNotEmpty) yield delta;
  }
  if (!completed) throw const ModelIncompleteFailure('连接中断，未完成的回复没有保存');
}
