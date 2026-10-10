import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../model_runtime.dart';
import '../model_protocol.dart';
import '../room_protocol.dart';
import 'agent_types.dart';
import 'agent_limits.dart';

/// The sidecar receives visible text/tools; provider state stays in this bridge.
class AgentProviderBridge {
  AgentProviderBridge(
    this.settings, {
    http.Client Function()? clientFactory,
    this.totalTimeout = const Duration(seconds: 180),
    this.idleTimeout = const Duration(seconds: 45),
  }) : _factory = clientFactory ?? http.Client.new;
  final RoomSettings settings;
  final http.Client Function() _factory;
  final Duration totalTimeout, idleTimeout;
  final _active = <http.Client>{};
  final _states = <String, ModelCompletion>{};
  int _epoch = 0, _sequence = 0;
  ApiFailure? lastFailure;
  AgentEmit? onProgress;
  static const limits = ModelLimits(
    textBytes: agentMaxModelBytes,
    argumentBytes: agentMaxActionChars,
    eventBytes: agentMaxJsonBytes,
    wireBytes: agentMaxStreamBytes,
  );
  void clearFailure() => lastFailure = null;
  void beginTurn() {
    _states.clear();
    clearFailure();
  }

  void endTurn() => _states.clear();
  void cancel() {
    _epoch++;
    _states.clear();
    for (final client in _active) {
      client.close();
    }
    _active.clear();
  }

  Map<String, dynamic> _requestBody(
    Map<String, dynamic> input, {
    required bool stream,
  }) {
    final runtime = ModelRuntime(settings)..require('text');
    final protocol = roomProtocol(roomChatEndpoint(settings.llmUrl));
    final raw = (input['messages'] as List).cast<Map>();
    final lastUser = raw.lastIndexWhere((m) => m['role'] == 'user');
    final messages = <Map<String, dynamic>>[],
        responseInput = <Map<String, dynamic>>[];
    final systems = <String>[], names = <String, String>{};
    final pending = <String>{}, resolved = <String>{};
    for (var index = 0; index < raw.length; index++) {
      final m = raw[index], role = m['role'];
      if (role == 'system' || role == 'developer') {
        systems.add(modelText(m['content']));
        continue;
      }
      if (!['assistant', 'user', 'tool'].contains(role)) {
        throw const ApiFailure('Agent 消息角色无效');
      }
      // Completed tasks retain visible conversation, not obsolete tool/state chains.
      if (index < lastUser && role == 'tool') continue;
      final calls = index < lastUser
          ? <Map>[]
          : (m['tool_calls'] as List? ?? []).cast<Map>();
      if (role == 'tool') {
        final id = m['tool_call_id'] as String? ?? '';
        if (!pending.remove(id) || !resolved.add(id)) {
          throw const ApiFailure('Agent 工具结果与调用不匹配');
        }
        final content = modelText(m['content']);
        var isError = m['isError'] == true;
        try {
          final data = jsonDecode(content);
          if (data is Map) {
            isError |=
                data['error'] != null ||
                data['declined'] == true ||
                data['isError'] == true ||
                data['exitCode'] is int && data['exitCode'] != 0;
          }
        } catch (_) {}
        if (protocol == 'responses') {
          responseInput.add({
            'type': 'function_call_output',
            'call_id': id,
            'output': content,
          });
        } else if (protocol == 'anthropic') {
          messages.add({
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': content,
                'is_error': isError,
              },
            ],
          });
        } else {
          messages.add({
            'role': 'tool',
            if (protocol == 'ollama')
              'tool_name': names[id]
            else
              'tool_call_id': id,
            'content': content,
          });
        }
        continue;
      }
      if (pending.isNotEmpty) throw const ApiFailure('Agent 工具结果不完整');
      final text = modelText(m['content']);
      ModelCompletion? state;
      if (calls.isNotEmpty) {
        if (calls.length > 6) throw const ApiFailure('Agent 工具调用数量过多');
        for (final c in calls) {
          final call = ModelCall(
            c['id'] as String? ?? '',
            c['function']?['name'] as String? ?? '',
            c['function']?['arguments'] as String? ?? '{}',
            maxBytes: limits.argumentBytes,
          );
          if (!pending.add(call.id) || resolved.contains(call.id)) {
            throw const ApiFailure('Agent 工具调用标识重复');
          }
          names[call.id] = call.name;
          final cached = _states[call.id];
          if (cached != null) {
            if (!cached.calls.any(
              (p) =>
                  p.id == call.id &&
                  p.name == call.name &&
                  modelArgumentKey(p.arguments) ==
                      modelArgumentKey(call.arguments),
            )) {
              throw const ApiFailure('Agent 工具调用内容已改变');
            }
            state ??= cached;
            if (!identical(state, cached)) {
              throw const ApiFailure('Agent 工具续接分组无效');
            }
          }
        }
        if (state != null &&
            state.calls
                .map((c) => c.id)
                .toSet()
                .difference(pending)
                .isNotEmpty) {
          throw const ApiFailure('Agent 工具续接不完整');
        }
      }
      if (protocol == 'responses') {
        if (state != null) {
          responseInput.addAll(state.items);
        } else {
          if (text.isNotEmpty) {
            responseInput.add({'role': role, 'content': text});
          }
          for (final c in calls) {
            responseInput.add({
              'type': 'function_call',
              'call_id': c['id'],
              'name': c['function']['name'],
              'arguments': c['function']['arguments'],
            });
          }
        }
      } else if (protocol == 'anthropic') {
        final content =
            state?.items ??
            [
              if (text.isNotEmpty) {'type': 'text', 'text': text},
              for (final c in calls)
                {
                  'type': 'tool_use',
                  'id': c['id'],
                  'name': c['function']['name'],
                  'input': jsonDecode(c['function']['arguments'] as String),
                },
            ];
        if (content.isNotEmpty) {
          messages.add({'role': role, 'content': content});
        }
      } else {
        final item = <String, dynamic>{
          'role': role,
          'content': text.isEmpty && calls.isNotEmpty ? null : text,
          if (calls.isNotEmpty) 'tool_calls': calls,
        };
        if (state != null &&
            state.items.firstOrNull?['reasoning_content'] is String) {
          item['reasoning_content'] = state.items.first['reasoning_content'];
        }
        if (protocol == 'ollama' && calls.isNotEmpty) {
          if (state?.items.firstOrNull?['thinking'] is String) {
            item['thinking'] = state!.items.first['thinking'];
          }
          item['tool_calls'] = [
            for (final c in calls)
              {
                'function': {
                  'name': c['function']['name'],
                  'arguments': jsonDecode(c['function']['arguments'] as String),
                },
              },
          ];
        }
        messages.add(item);
      }
    }
    if (pending.isNotEmpty) throw const ApiFailure('Agent 工具调用没有配对结果');
    final tools = (input['tools'] as List? ?? []).cast<Map>();
    if (tools.isNotEmpty) runtime.require('tools');
    final body = <String, dynamic>{
      'model': settings.model,
      'stream': stream && !runtime.unsupported('streaming'),
    };
    if (protocol == 'responses') {
      body.addAll({
        'instructions': systems.join('\n'),
        'input': responseInput,
        'store': false,
        if (tools.isNotEmpty)
          'tools': [
            for (final t in tools)
              {
                'type': 'function',
                ...Map<String, dynamic>.from(t['function'] as Map),
                'strict': false,
              },
          ],
      });
    } else if (protocol == 'anthropic') {
      final merged = <Map<String, dynamic>>[];
      for (final item in messages) {
        if (merged.isNotEmpty && merged.last['role'] == item['role']) {
          (merged.last['content'] as List).addAll(item['content'] as List);
        } else {
          merged.add(item);
        }
      }
      body.addAll({
        'system': systems.join('\n'),
        'messages': merged,
        'max_tokens': input['max_tokens'] ?? 8192,
        if (tools.isNotEmpty)
          'tools': [
            for (final t in tools)
              {
                'name': t['function']['name'],
                'description': t['function']['description'] ?? '',
                'input_schema': t['function']['parameters'],
              },
          ],
      });
    } else {
      body['messages'] = [
        if (systems.isNotEmpty)
          {'role': 'system', 'content': systems.join('\n')},
        ...messages,
      ];
      if (tools.isNotEmpty) body['tools'] = tools;
      if (protocol == 'openai') {
        for (final key in [
          'temperature',
          'top_p',
          'max_tokens',
          'max_completion_tokens',
          'stop',
          'seed',
        ]) {
          if (input.containsKey(key)) body[key] = input[key];
        }
        if (RegExp(
          'moonshot|kimi',
          caseSensitive: false,
        ).hasMatch('${settings.llmUrl} ${settings.model}')) {
          body['temperature'] = 1;
        }
      }
    }
    final configured = runtime.apply(body);
    modelBound(configured, agentMaxJsonBytes);
    return configured;
  }

  void _remember(ModelCompletion value) {
    for (final call in value.calls) {
      final prior = _states[call.id];
      if (prior != null) {
        // OpenCode creates a new MCP request ID for a new model call. Reject
        // reused model IDs here, before another side effect can reach MCP.
        throw const ApiFailure('模型重复使用工具调用标识，操作已停止');
      }
      _states[call.id] = value;
    }
    modelBound(
      _states.values.toSet().map((c) => c.continuation).toList(),
      agentMaxModelBytes,
    );
  }

  Map<String, dynamic> _completion(ModelCompletion value) => {
    'id': 'chatcmpl-room-${++_sequence}',
    'object': 'chat.completion',
    'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'model': settings.model,
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content': value.reply,
          if (value.calls.isNotEmpty)
            'tool_calls': value.calls.map((c) => c.openAi).toList(),
        },
        'finish_reason': value.calls.isEmpty ? 'stop' : 'tool_calls',
      },
    ],
    'usage': {
      'prompt_tokens':
          value.usage['prompt_tokens'] ?? value.usage['input_tokens'] ?? 0,
      'completion_tokens':
          value.usage['completion_tokens'] ?? value.usage['output_tokens'] ?? 0,
      'total_tokens':
          value.usage['total_tokens'] ??
          ((value.usage['prompt_tokens'] ?? value.usage['input_tokens'] ?? 0)
                  as num) +
              ((value.usage['completion_tokens'] ??
                      value.usage['output_tokens'] ??
                      0)
                  as num),
    },
  };

  Future<ModelCompletion> _run(
    Map<String, dynamic> input, {
    required bool stream,
    Future<void> Function(ModelWireEvent)? onEvent,
  }) async {
    final endpoint = roomChatEndpoint(settings.llmUrl),
        protocol = roomProtocol(endpoint);
    final client = _factory(), epoch = _epoch;
    _active.add(client);
    var expired = false;
    final deadline = Timer(totalTimeout, () {
      expired = true;
      client.close();
    });
    void check() {
      if (epoch != _epoch) throw const ApiFailure('Agent 已停止');
      if (expired) throw const ApiFailure('Agent 模型响应超时', status: 504);
    }

    Future<List<int>> read(http.StreamedResponse response) async {
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        check();
        bytes.addAll(chunk);
        if (bytes.length > agentMaxJsonBytes) {
          throw const ApiFailure('Agent 模型返回内容过大');
        }
      }
      check();
      return bytes;
    }

    try {
      onProgress?.call(AgentEvent('modelProgress', '正在连接模型'));
      final body = _requestBody(input, stream: stream);
      Future<http.StreamedResponse> send() => client
          .send(
            http.Request('POST', endpoint)
              ..followRedirects = false
              ..headers.addAll(roomChatHeaders(settings, endpoint))
              ..body = jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      var response = await send();
      if (response.statusCode != 200) {
        final reason = utf8
            .decode(await read(response), allowMalformed: true)
            .toLowerCase();
        if (stream &&
            [400, 422].contains(response.statusCode) &&
            RegExp(r'stream').hasMatch(reason) &&
            RegExp(
              r'unsupported|not support|not allowed|must be false|does not support',
            ).hasMatch(reason)) {
          body['stream'] = false;
          response = await send();
        } else if ([400, 422].contains(response.statusCode) &&
            RegExp(r'tool|function').hasMatch(reason) &&
            RegExp(r'unsupported|not support|not allowed|unknown|unexpected')
                .hasMatch(reason)) {
          throw ApiFailure(
            'tools unsupported: 请使用结构化兼容模式',
            status: response.statusCode,
          );
        } else {
          throw providerFailure('Agent 模型', response.statusCode);
        }
      }
      if (response.statusCode != 200) {
        throw providerFailure('Agent 模型', response.statusCode);
      }
      final contentType = response.headers['content-type'] ?? '';
      ModelCompletion? value;
      if (contentType.contains('application/json') ||
          !stream ||
          body['stream'] == false) {
        value = ModelCompletion.json(
          jsonDecode(utf8.decode(await read(response))) as Map,
          protocol,
          limits: limits,
          allowTools: true,
          callPrefix: 'ollama_${++_sequence}',
        );
        if (value.reply.isNotEmpty) {
          await onEvent?.call(ModelWireEvent('text', text: value.reply));
        }
      } else {
        await for (final event in decodeModelStream(
          response.stream.timeout(idleTimeout).map((chunk) {
            check();
            return chunk;
          }),
          protocol,
          limits: limits,
          allowTools: true,
          callPrefix: 'ollama_${++_sequence}',
        )) {
          check();
          if (event.type == 'complete') {
            value = event.completion;
          } else {
            final phase = event.type == 'text' ? 'answer' : event.text;
            onProgress?.call(
              AgentEvent(
                'modelProgress',
                phase == 'reasoning'
                    ? '模型正在整理任务'
                    : phase == 'tools'
                    ? '正在准备工具操作'
                    : '正在生成回复',
                data: {'activity': true, 'phase': phase},
              ),
            );
            await onEvent?.call(event);
          }
        }
      }
      check();
      if (value == null) throw const ModelIncompleteFailure('Agent 模型没有完整返回结果');
      _remember(value);
      return value;
    } catch (error) {
      final failure = error is ApiFailure
          ? error
          : expired || error is TimeoutException
          ? const ApiFailure('Agent 模型响应超时', status: 504)
          : const ApiFailure('Agent 模型连接或协议异常', status: 502);
      lastFailure = failure;
      throw failure;
    } finally {
      deadline.cancel();
      client.close();
      _active.remove(client);
    }
  }

  Future<Map<String, dynamic>> complete(Map<String, dynamic> input) async =>
      _completion(await _run(input, stream: false));

  Future<void> handle(HttpRequest request, Map<String, dynamic> input) async {
    if (input['stream'] != true) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(await complete(input)));
      await request.response.close();
      return;
    }
    var opened = false;
    final id = 'chatcmpl-room-${++_sequence}';
    Future<void> write(Map<String, dynamic> chunk) async {
      if (!opened) {
        request.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        request.response.headers.set('Cache-Control', 'no-cache');
        request.response.bufferOutput = false;
        opened = true;
      }
      request.response.write(
        'data: ${jsonEncode({'id': id, 'object': 'chat.completion.chunk', 'model': settings.model, ...chunk})}\n\n',
      );
      await request.response.flush();
    }

    try {
      final value = await _run(
        input,
        stream: true,
        onEvent: (event) async {
          if (event.type == 'text') {
            await write({
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': event.text},
                  'finish_reason': null,
                },
              ],
            });
          }
        },
      );
      if (value.calls.isNotEmpty) {
        await write({
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  for (var i = 0; i < value.calls.length; i++)
                    {'index': i, ...value.calls[i].openAi},
                ],
              },
              'finish_reason': null,
            },
          ],
        });
      }
      await write({
        'choices': [
          {
            'index': 0,
            'delta': {},
            'finish_reason': value.calls.isEmpty ? 'stop' : 'tool_calls',
          },
        ],
      });
      await write({'choices': [], 'usage': _completion(value)['usage']});
      request.response.write('data: [DONE]\n\n');
      await request.response.flush();
    } catch (error) {
      if (!opened) rethrow;
      try {
        await write({
          'error': {'message': lastFailure?.message ?? 'Agent 模型请求失败'},
        });
      } catch (_) {}
    } finally {
      if (opened) await request.response.close();
    }
  }
}
