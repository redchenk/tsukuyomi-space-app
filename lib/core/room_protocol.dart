import 'models.dart';
import 'model_runtime.dart';
import 'model_protocol.dart';

Uri roomChatEndpoint(String value) {
  var uri = endpointUri(value);
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/responses') ||
      path.endsWith('/messages') ||
      path.endsWith('/api/chat') ||
      path.endsWith('/chat/completions')) {
    return uri.replace(path: path);
  }
  if (uri.host == 'api.anthropic.com') {
    return uri.replace(
      path: path.endsWith('/v1') ? '$path/messages' : '$path/v1/messages',
    );
  }
  if (path.endsWith('/anthropic')) {
    return uri.replace(path: '$path/v1/messages');
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
  if (roomProtocol(uri) == 'anthropic') ...{
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
  final runtime = ModelRuntime(s)..require('text');
  if (image != null) runtime.require('image');
  return runtime.apply(
    _roomChatBody(
      s,
      system,
      history,
      text,
      image: image,
      stream: stream && !runtime.unsupported('streaming'),
      jsonObject: jsonObject,
    ),
  );
}

Map<String, dynamic> _roomChatBody(
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
      'store': false,
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
    ...roomChatOptions(roomChatEndpoint(s.llmUrl), s.model),
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
  await for (final event in decodeModelStream(
    bytes,
    protocol,
    limits: ModelLimits(textBytes: maxChars * 4, eventBytes: maxEventChars),
  )) {
    if (event.type == 'text') yield event.text;
  }
}

Map<String, dynamic> roomChatOptions(Uri url, String model) {
  if (RegExp(r'/responses/?$|/messages/?$').hasMatch(url.path)) return {};
  if (RegExp(
    r'moonshot|kimi',
    caseSensitive: false,
  ).hasMatch('${url.host} $model')) {
    return {'temperature': 1};
  }
  if (RegExp(
    r'^(?:o[1-9](?:-|$)|gpt-(?:[5-9]|[1-9]\d)(?:[.-]|$))',
    caseSensitive: false,
  ).hasMatch(model)) {
    return {};
  }
  final qwen =
      [
        'dashscope.aliyuncs.com',
        'dashscope-intl.aliyuncs.com',
        'dashscope-us.aliyuncs.com',
      ].contains(url.host) &&
      RegExp(
        r'^qwen3\.8-(?:flash|max)(?:-|$)',
        caseSensitive: false,
      ).hasMatch(model);
  return {'temperature': qwen ? .6 : .7, if (qwen) 'preserve_thinking': false};
}
