import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'models.dart';
import 'room_reference.dart';

const _maxModels = 2000, _maxBytes = 2 * 1024 * 1024;
final _workspaceHost = RegExp(
  r'^[a-z0-9][a-z0-9-]{0,63}\.(cn-beijing|us-east-1|ap-southeast-1|ap-northeast-1|eu-central-1|cn-hongkong)\.maas\.aliyuncs\.com$',
);

String catalogProvider(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return 'custom';
  if (['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host) &&
      uri.port == 11434) {
    return 'ollama';
  }
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.port != 443) {
    return 'custom';
  }
  if (_workspaceHost.hasMatch(uri.host)) return 'aliyun';
  for (final entry in RoomReference.map('catalogProviders').entries) {
    if ((entry.value['hosts'] as List).contains(uri.host)) return entry.key;
  }
  return 'custom';
}

({String provider, Uri url, Map<String, String> headers}) catalogPlan(
  RoomSettings settings, {
  String cursor = '',
}) {
  final provider = catalogProvider(settings.llmUrl);
  final spec = RoomReference.map('catalogProviders')[provider];
  if (spec == null) {
    throw ApiFailure(
      provider == 'ollama' ? '本机模型请填写已下载的模型名称。' : '自定义端点不自动转发密钥；请手动填写完整模型 ID。',
    );
  }
  if (spec['reason'] != null) throw ApiFailure('${spec['reason']}');
  final chat = endpointUri(settings.llmUrl);
  if (!RegExp(r'/(?:chat/completions|responses|messages)/?$')
      .hasMatch(chat.path)) {
    throw const ApiFailure('请填写服务商的完整聊天 API 端点。');
  }
  final key = settings.apiKey.trim();
  if (settings.apiKey.length > 2048 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(settings.apiKey)) {
    throw const ApiFailure('API 密钥格式无效。');
  }
  if (key.isEmpty && provider != 'openrouter') {
    throw const ApiFailure('填写当前服务商的 API 密钥后可更新模型列表。');
  }
  if (cursor.length > 1024 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(cursor)) {
    throw const ApiFailure('模型列表分页游标无效。');
  }
  var host = chat.host, path = '${spec['path'] ?? ''}';
  if (provider == 'aliyun') {
    path = '/api/v1/models';
    if ([
      'dashscope.aliyuncs.com',
      'dashscope-us.aliyuncs.com',
    ].contains(host)) {
      final workspace = settings.option('aliyunWorkspaceId');
      if (!RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(workspace)) {
        throw const ApiFailure('此地域的百炼模型列表需要工作空间 ID，可在高级设置填写。');
      }
      host =
          '$workspace.${host == 'dashscope.aliyuncs.com' ? 'cn-beijing' : 'us-east-1'}.maas.aliyuncs.com';
    }
  }
  if (provider == 'openrouter' && key.isEmpty) path = '/api/v1/models';
  final query = <String, String>{
    for (final e in (spec['query'] as Map? ?? {}).entries)
      '${e.key}': '${e.value}',
  };
  switch (provider) {
    case 'gemini':
      query.addAll({
        'pageSize': '1000',
        if (cursor.isNotEmpty) 'pageToken': cursor,
      });
    case 'aliyun':
      if (cursor.isNotEmpty && !RegExp(r'^[1-9]\d{0,2}$').hasMatch(cursor)) {
        throw const ApiFailure('模型列表分页游标无效。');
      }
      query.addAll({
        'page_no': cursor.isEmpty ? '1' : cursor,
        'page_size': '100',
        'capabilities': 'TG',
      });
    case 'openrouter':
      if (cursor.isNotEmpty && !RegExp(r'^\d{1,5}$').hasMatch(cursor)) {
        throw const ApiFailure('模型列表分页游标无效。');
      }
      query.addAll({'offset': cursor.isEmpty ? '0' : cursor, 'limit': '500'});
    default:
      if (cursor.isNotEmpty) throw const ApiFailure('此服务商不支持该分页游标。');
  }
  return (
    provider: provider,
    url: Uri.https(host, path, query.isEmpty ? null : query),
    headers: {
      'Accept': 'application/json',
      if (key.isNotEmpty)
        provider == 'gemini' ? 'x-goog-api-key' : 'Authorization':
            provider == 'gemini' ? key : 'Bearer $key',
    },
  );
}

Map<String, bool> catalogCapabilities(Map row) {
  final c = row['capabilities'] is Map ? row['capabilities'] as Map : {};
  final architecture = row['architecture'] is Map
      ? row['architecture'] as Map
      : {};
  final input =
      architecture['input_modalities'] ??
      row['input_modalities'] ??
      row['inputModalities'];
  return {
    if (input is List && input.isNotEmpty) 'image': input.contains('image'),
    for (final entry in {
      'vision': 'image',
      'completion_chat': 'text',
      'function_calling': 'tools',
      'streaming': 'streaming',
    }.entries)
      if (c[entry.key] is bool) entry.value: c[entry.key] as bool,
    if (row['supported_parameters'] is List)
      'tools': (row['supported_parameters'] as List).contains('tools'),
  };
}

({List<Map<String, dynamic>> models, String cursor}) normalizeCatalog(
  dynamic payload,
  String provider, {
  String cursor = '',
}) {
  if (payload is! Map && payload is! List ||
      payload is Map &&
          (payload['error'] != null || payload['success'] == false)) {
    throw const ApiFailure('服务商返回的模型列表无效。');
  }
  final rows = provider == 'gemini'
      ? payload['models']
      : provider == 'aliyun'
      ? (payload['output']?['models'])
      : payload is List
      ? payload
      : payload['data'];
  if (rows is! List || rows.length > _maxModels) {
    throw const ApiFailure('服务商返回的模型列表格式或大小不符合要求。');
  }
  final result = <Map<String, dynamic>>[], seen = <String>{};
  for (final row in rows.whereType<Map>()) {
    final id = provider == 'gemini'
        ? '${row['name'] ?? ''}'.replaceFirst(RegExp(r'^models/'), '')
        : row['id'] ?? row['model'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 240 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(id) ||
        !seen.add(id) ||
        row['active'] == false ||
        row['archived'] == true) {
      continue;
    }
    final shutdown = DateTime.tryParse('${row['shutdown_date'] ?? ''}');
    if (shutdown != null && !shutdown.isAfter(DateTime.now())) continue;
    if (provider == 'gemini' &&
        !(row['supportedGenerationMethods'] is List &&
            (row['supportedGenerationMethods'] as List).contains(
              'generateContent',
            ))) {
      continue;
    }
    if (provider == 'mistral' &&
        row['capabilities']?['completion_chat'] == false) {
      continue;
    }
    if (provider == 'together' &&
        row['type'] != null &&
        row['type'] != 'chat') {
      continue;
    }
    final output =
        row['architecture']?['output_modalities'] ??
        row['output_modalities'] ??
        row['inference_metadata']?['response_modality'];
    if (output is List && output.isNotEmpty && !output.contains('text')) {
      continue;
    }
    if (RegExp(
      r'embedding|embed-|rerank|moderation|whisper|(?:^|[-/])tts(?:[-/]|$)|dall-e|image-generation|speech|(?:^|[-/])guard(?:[-/]|$)',
      caseSensitive: false,
    ).hasMatch(id)) {
      continue;
    }
    result.add({
      'id': id,
      'nativeId': id,
      'label': '${row['displayName'] ?? row['display_name'] ?? row['name'] ?? id}'
          .substring(
            0,
            min(
              160,
              '${row['displayName'] ?? row['display_name'] ?? row['name'] ?? id}'
                  .length,
            ),
          ),
      'capabilities': catalogCapabilities(row),
      'contextLength':
          row['context_length'] ??
          row['context_window'] ??
          row['max_context_length'] ??
          row['inputTokenLimit'] ??
          row['model_info']?['max_input_tokens'] ??
          0,
    });
  }
  final next = provider == 'gemini'
      ? '${payload['nextPageToken'] ?? ''}'
      : provider == 'aliyun' &&
            (num.tryParse('${payload['output']?['total']}') ?? 0) >
                (int.tryParse(cursor) ?? 1) * 100
      ? '${(int.tryParse(cursor) ?? 1) + 1}'
      : provider == 'openrouter' && rows.length == 500
      ? '${(int.tryParse(cursor) ?? 0) + 500}'
      : '';
  if (next.length > 1024) throw const ApiFailure('服务商返回了无效的分页游标。');
  return (models: result, cursor: next);
}

/// Native read-only lists go directly to the selected official provider. Keys
/// never follow redirects or reach another provider; only metadata is cached.
class ModelCatalog {
  ModelCatalog({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final String _salt = List.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ).join(',');
  final _cache = <String, ({DateTime at, List<Map<String, dynamic>> rows})>{};
  bool _closed = false;
  final _pending = <Completer<void>>{};
  Future<List<Map<String, dynamic>>> load(
    RoomSettings settings, {
    bool refresh = false,
  }) async {
    catalogPlan(settings);
    final cacheId = sha256
        .convert(
          utf8.encode(
            '$_salt|${settings.llmUrl}|${settings.apiKey}|${settings.option('aliyunWorkspaceId')}',
          ),
        )
        .toString();
    final cached = _cache[cacheId];
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at).inHours < 6) {
      return cached.rows;
    }
    final abort = Completer<void>(), clock = Stopwatch()..start();
    _pending.add(abort);
    final all = <String, Map<String, dynamic>>{}, cursors = <String>{};
    var cursor = '';
    try {
      for (var page = 0; page < 8; page++) {
        if (_closed || clock.elapsedMilliseconds >= 15000) {
          throw const ApiFailure('模型列表请求已取消或超时');
        }
        final plan = catalogPlan(settings, cursor: cursor);
        final request =
            http.AbortableRequest('GET', plan.url, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers.addAll(plan.headers);
        final timeout = Duration(
          milliseconds: 15000 - clock.elapsedMilliseconds,
        );
        final response = await _client.send(request).timeout(timeout);
        if (response.statusCode != 200) {
          throw providerFailure('模型列表', response.statusCode);
        }
        var length = 0;
        final bytes = <int>[];
        await for (final chunk in response.stream.timeout(
          Duration(milliseconds: max(1, 15000 - clock.elapsedMilliseconds)),
        )) {
          length += chunk.length;
          if (length > _maxBytes || clock.elapsedMilliseconds > 15000) {
            throw const ApiFailure('服务商返回的模型列表过大或超时');
          }
          bytes.addAll(chunk);
        }
        final normalized = normalizeCatalog(
          jsonDecode(utf8.decode(bytes)),
          plan.provider,
          cursor: cursor,
        );
        for (final item in normalized.models) {
          all[item['id']] = item;
        }
        if (all.length > _maxModels) throw const ApiFailure('模型列表数量超过限制');
        cursor = normalized.cursor;
        if (cursor.isEmpty) break;
        if (!cursors.add(cursor) || page == 7) {
          throw const ApiFailure('模型列表分页超过限制');
        }
      }
      if (_closed || abort.isCompleted) throw const ApiFailure('模型列表请求已取消');
      final rows = all.values.toList();
      if (_cache.length >= 8) _cache.remove(_cache.keys.first);
      _cache[cacheId] = (at: DateTime.now(), rows: rows);
      return rows;
    } on FormatException {
      throw const ApiFailure('服务商返回的模型列表不是有效 JSON');
    } on TimeoutException {
      throw const ApiFailure('模型列表请求超时，请重试');
    } finally {
      _pending.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  void cancel() {
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    _pending.clear();
    _cache.clear();
  }

  void close() {
    cancel();
    _closed = true;
    _cache.clear();
    _client.close();
  }
}
