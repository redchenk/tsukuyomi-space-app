import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/models.dart';
import '../../core/room_archive.dart';
import 'site_guide_data.dart';

class SiteGuideReference {
  static final data = jsonMap(jsonDecode(siteGuideJson));
  static Map<String, dynamic> copy(String language) =>
      jsonMap(jsonMap(data['copy'])[language] ?? jsonMap(data['copy'])['zh']);
  static String systemPrompt(String language, String routeName) =>
      '${jsonMap(data['prompts'])[language] ?? jsonMap(data['prompts'])['zh']}'
          .replaceAll(
            '__SITE_ROUTE__',
            routeName.isEmpty
                ? 'unknown'
                : routeName.substring(0, routeName.length.clamp(0, 80)),
          );
  static List<Map<String, dynamic>> guides(String route) {
    final name = routeName(route);
    final guides = jsonRows(data['guides']);
    return [
      ...guides.where((g) => (g['routes'] as List).contains(name)),
      ...guides.where((g) => !(g['routes'] as List).contains(name)),
    ];
  }

  static String routeName(String path) {
    final uri = Uri.tryParse(path),
        parts = uri?.path.split('/').where((s) => s.isNotEmpty).toList() ?? [];
    if (parts.isEmpty) return 'access';
    if (parts.first == 'room') {
      return parts.length > 1
          ? (parts[1] == 'settings' ? 'roomSettings' : 'roomShared')
          : 'room';
    }
    if (parts.first == 'gallery' && parts.length > 1 && parts[1] == 'manage') {
      return 'galleryManage';
    }
    if (parts.first == 'wiki' && parts.length > 2) {
      return parts[1] == 'characters' ? 'wikiCharacter' : 'wikiTerm';
    }
    if (parts.first == 'friend-links' &&
        parts.length > 1 &&
        parts[1] == 'apply') {
      return 'friendLinkApply';
    }
    if (['users', 'user'].contains(parts.first) && parts.length > 1) {
      return 'userProfile';
    }
    return const {
          'user-center': 'userCenter',
          'user': 'userCenter',
          'room-settings': 'roomSettings',
          'access': 'accessAlias',
          'friend-links': 'friendLinks',
          'articles': 'articleDetail',
          'attachments': 'attachments',
          'agent-os': 'agentOs',
        }[parts.first] ??
        parts.first;
  }
}

Uri siteGuideEndpoint(String value) {
  var raw = value.trim();
  if (RegExp(
    r'^(localhost|127\.0\.0\.1|\[::1\])(?::|/|$)',
    caseSensitive: false,
  ).hasMatch(raw)) {
    raw = 'http://$raw';
  }
  var uri = endpointUri(raw);
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host) &&
      (!uri.hasPort || uri.port == 11434)) {
    uri = uri.replace(scheme: 'http', host: 'localhost', port: 11434);
    if (path.isEmpty || path == '/api') path = '/api/chat';
    if (path == '/v1') path = '/v1/chat/completions';
  }
  if (['api.openai.com', 'api.x.ai'].contains(uri.host) && path == '/v1') {
    path = '/v1/responses';
  }
  if (['xiaomimimo.com', 'token-plan-cn.xiaomimimo.com'].contains(uri.host) &&
      path == '/v1') {
    path = '/v1/chat/completions';
  }
  return uri.replace(path: path);
}

bool siteGuideLocal(Uri endpoint) =>
    endpoint.scheme == 'http' &&
    [
      'localhost',
      '127.0.0.1',
      '::1',
      '[::1]',
      '10.0.2.2',
    ].contains(endpoint.host) &&
    endpoint.port == 11434;

class SiteGuideModelStatus {
  const SiteGuideModelStatus({
    this.configured = false,
    this.local = false,
    this.model = '',
    this.endpoint,
  });
  factory SiteGuideModelStatus.read(RoomSettings settings) {
    try {
      final endpoint = siteGuideEndpoint(settings.llmUrl),
          local = siteGuideLocal(endpoint);
      final configured =
          !settings.demo &&
          settings.model.trim().isNotEmpty &&
          (local || settings.apiKey.trim().isNotEmpty);
      return SiteGuideModelStatus(
        configured: configured,
        local: local,
        model: configured ? settings.model.trim() : '',
        endpoint: endpoint,
      );
    } catch (_) {
      return const SiteGuideModelStatus();
    }
  }
  final bool configured, local;
  final String model;
  final Uri? endpoint;
}

List<Map<String, dynamic>> siteGuideHistory(
  List<Map<String, dynamic>> history,
) {
  final items = history
      .where((h) => ['user', 'assistant'].contains(h['role']))
      .toList();
  return [
    for (final item in items.skip((items.length - 8).clamp(0, items.length)))
      {
        'role': item['role'],
        'content': '${item['content'] ?? ''}'.substring(
          0,
          '${item['content'] ?? ''}'.length.clamp(0, 2400),
        ),
      },
  ];
}

Map<String, dynamic> siteGuideRequestBody(
  RoomSettings settings,
  Uri endpoint,
  String system,
  List<Map<String, dynamic>> history,
  String question,
) {
  final messages = [
    ...history,
    {'role': 'user', 'content': question},
  ];
  final model = settings.model.trim();
  if (siteGuideLocal(endpoint) &&
      RegExp(r'^/api/chat/?$').hasMatch(endpoint.path)) {
    return {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        ...messages,
      ],
      'stream': false,
      'options': {'temperature': .25},
    };
  }
  if (['api.openai.com', 'api.x.ai'].contains(endpoint.host) &&
      RegExp(r'/v1/responses/?$').hasMatch(endpoint.path)) {
    return {
      'model': model,
      'instructions': system,
      'input': messages,
      'max_output_tokens': 900,
    };
  }
  if (RegExp(
    r'api\.anthropic\.com|anthropic\.com/v1/messages|minimaxi\.com/anthropic|/anthropic/v1/messages|MiniMax-M2',
    caseSensitive: false,
  ).hasMatch('$endpoint $model')) {
    return {
      'model': model,
      'system': system,
      'messages': messages,
      'max_tokens': 900,
      'temperature': .25,
      'stream': false,
    };
  }
  return {
    'model': model,
    'messages': [
      {'role': 'system', 'content': system},
      ...messages,
    ],
    'temperature':
        RegExp(
          r'api\.moonshot\.cn|kimi',
          caseSensitive: false,
        ).hasMatch('$endpoint $model')
        ? 1
        : .25,
  };
}

Map<String, String> siteGuideHeaders(RoomSettings settings, Uri endpoint) => {
  'Content-Type': 'application/json',
  if (!siteGuideLocal(endpoint)) ...{
    if (endpoint.host == 'api.anthropic.com') ...{
      'x-api-key': settings.apiKey,
      'anthropic-version': '2023-06-01',
    } else
      'Authorization': 'Bearer ${settings.apiKey}',
    if (endpoint.host == 'openrouter.ai') ...{
      'HTTP-Referer': endpointUri(settings.siteUrl).origin,
      'X-OpenRouter-Title': 'Tsukuyomi Space Guide',
    },
  },
};

String siteGuideReply(dynamic data) {
  final value = jsonMap(data);
  if (value['output_text'] is String) return '${value['output_text']}'.trim();
  final output = jsonRows(value['output'])
      .expand((i) => jsonRows(i['content']))
      .where((i) => ['output_text', 'text'].contains(i['type']))
      .map((i) => '${i['text'] ?? ''}')
      .join('\n')
      .trim();
  if (output.isNotEmpty) return output;
  final content = jsonRows(value['content'])
      .where((i) => i['type'] == 'text')
      .map((i) => '${i['text'] ?? ''}')
      .join('\n')
      .trim();
  if (content.isNotEmpty) return content;
  final choice = jsonRows(value['choices']).firstOrNull ?? {};
  return '${jsonMap(choice['message'])['content'] ?? choice['text'] ?? jsonMap(value['message'])['content'] ?? value['response'] ?? value['reply'] ?? ''}'
      .trim();
}

/// Owns an independent, bounded non-streaming transport. It never cancels Room
/// chat, submits private memories, or exposes model credentials in guide errors.
class SiteGuideService {
  SiteGuideService({
    http.Client Function()? clientFactory,
    this.timeout = const Duration(seconds: 75),
  }) : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  final Duration timeout;
  http.Client? _active;
  Completer<void>? _canceled;
  int _generation = 0;
  void cancel() {
    _generation++;
    if (!(_canceled?.isCompleted ?? true)) _canceled!.complete();
    _canceled = null;
    _active?.close();
    _active = null;
  }

  Future<String> ask({
    required RoomSettings settings,
    required String question,
    List<Map<String, dynamic>> history = const [],
    String language = 'zh',
    String routeName = '',
    String? siteCookie,
  }) async {
    final clean = question.trim().substring(
      0,
      question.trim().length.clamp(0, 800),
    );
    if (clean.isEmpty) {
      throw ApiFailure(
        language == 'en'
            ? 'Enter a question first.'
            : language == 'ja'
            ? '質問を入力してください。'
            : '请先输入问题。',
      );
    }
    final status = SiteGuideModelStatus.read(settings);
    if (!status.configured) {
      throw ApiFailure(
        language == 'en'
            ? 'Configure an LLM in Room Settings first.'
            : language == 'ja'
            ? '先にルーム設定で LLM を接続してください。'
            : '请先在 Room 设置中接入 LLM。',
      );
    }
    cancel();
    final ticket = _generation, client = _clientFactory();
    _active = client;
    final canceled = Completer<void>();
    _canceled = canceled;
    var expired = false;
    final deadline = Timer(timeout, () {
      expired = true;
      client.close();
    });
    final endpoint = status.endpoint!,
        conversation = siteGuideHistory(history),
        system = SiteGuideReference.systemPrompt(language, routeName);
    final proxy = settings.flag('llmProxy') && !status.local;
    try {
      final request =
          http.Request(
              'POST',
              proxy
                  ? endpointUri(settings.siteUrl).resolve('/api/chat')
                  : endpoint,
            )
            ..followRedirects = false
            ..headers.addAll(
              proxy
                  ? {
                      'Content-Type': 'application/json',
                      'Origin': endpointUri(settings.siteUrl).origin,
                      'X-Requested-With': 'XMLHttpRequest',
                      if (siteCookie?.isNotEmpty ?? false)
                        'Cookie': siteCookie!,
                    }
                  : siteGuideHeaders(settings, endpoint),
            )
            ..body = jsonEncode(
              proxy
                  ? {
                      'message': clean,
                      'conversation': conversation,
                      'apiKey': settings.apiKey,
                      'apiUrl': '$endpoint',
                      'model': settings.model,
                      'systemPrompt': system,
                    }
                  : siteGuideRequestBody(
                      settings,
                      endpoint,
                      system,
                      conversation,
                      clean,
                    ),
            );
      Future<String> readReply() async {
        final response = await client.send(request);
        final bytes = <int>[];
        await for (final part in response.stream) {
          bytes.addAll(part);
          if (bytes.length > 1024 * 1024) throw const ApiFailure('模型响应过大');
        }
        if (expired) throw TimeoutException('guide timeout');
        if (ticket != _generation) throw const ApiFailure('向导请求已停止');
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ApiFailure(
            'Model request failed (HTTP ${response.statusCode})',
            status: response.statusCode,
          );
        }
        final data = jsonMap(jsonDecode(utf8.decode(bytes)));
        if (proxy && data['success'] != true) {
          throw ApiFailure(
            '${data['message'] ?? 'The guide could not reach the configured model.'}',
          );
        }
        final reply = siteGuideReply(proxy ? data['data'] : data);
        if (reply.isEmpty) {
          throw const ApiFailure('The model returned an empty response.');
        }
        return reply;
      }

      return await Future.any<String>([
        readReply(),
        canceled.future.then((_) => throw const ApiFailure('向导请求已停止')),
      ]).timeout(
        timeout,
        onTimeout: () {
          expired = true;
          client.close();
          throw TimeoutException('guide timeout');
        },
      );
    } catch (e) {
      if (expired || e is TimeoutException) {
        throw ApiFailure(
          language == 'en'
              ? 'The model took too long to respond.'
              : language == 'ja'
              ? 'モデルの応答がタイムアウトしました。'
              : '模型响应超时，请稍后重试。',
        );
      }
      var message = e is ApiFailure ? e.message : '$e';
      if (settings.apiKey.isNotEmpty) {
        message = message.replaceAll(settings.apiKey, '[redacted]');
      }
      throw ApiFailure(
        message.substring(0, message.length.clamp(0, 300)),
        status: e is ApiFailure ? e.status : null,
      );
    } finally {
      deadline.cancel();
      client.close();
      if (identical(_active, client)) _active = null;
      if (identical(_canceled, canceled)) _canceled = null;
    }
  }

  void dispose() => cancel();
}
