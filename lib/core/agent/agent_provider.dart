import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../room_protocol.dart';
import 'agent_types.dart';
import 'agent_progress.dart';

/// Keeps Room's exact endpoints/headers/keys out of the sidecar configuration.
/// OpenCode sees an OpenAI-compatible API; all four Room protocols retain tools.
class AgentProviderBridge {
  AgentProviderBridge(this.settings, {http.Client Function()? clientFactory})
    : _factory = clientFactory ?? http.Client.new;
  final RoomSettings settings;
  final http.Client Function() _factory;
  final _active = <http.Client>{};
  ApiFailure? lastFailure;
  AgentEmit? onProgress;
  void clearFailure() => lastFailure = null;
  void cancel() {
    for (final client in _active) {
      client.close();
    }
    _active.clear();
  }

  Map<String, dynamic> _requestBody(
    Map<String, dynamic> input, {
    bool stream = false,
  }) {
    final endpoint = roomChatEndpoint(settings.llmUrl);
    final protocol = roomProtocol(endpoint);
    final messages = (input['messages'] as List).cast<Map>();
    final tools = (input['tools'] as List? ?? []).cast<Map>();
    final body = <String, dynamic>{};
    switch (protocol) {
      case 'responses':
        body.addAll({
          'model': settings.model,
          'stream': stream,
          'instructions': messages
              .where((m) => m['role'] == 'system')
              .map((m) => m['content'])
              .join('\n'),
          'input': [
            for (final m in messages)
              if (m['role'] == 'tool')
                {
                  'type': 'function_call_output',
                  'call_id': m['tool_call_id'],
                  'output': m['content'],
                }
              else if (m['role'] != 'system') ...[
                if (m['content'] != null && m['content'] != '')
                  {'role': m['role'], 'content': m['content']},
                for (final call in m['tool_calls'] as List? ?? [])
                  {
                    'type': 'function_call',
                    'call_id': call['id'],
                    'name': call['function']['name'],
                    'arguments': call['function']['arguments'],
                  },
              ],
          ],
          if (tools.isNotEmpty)
            'tools': [
              for (final tool in tools)
                {
                  'type': 'function',
                  ...Map<String, dynamic>.from(tool['function'] as Map),
                },
            ],
        });
      case 'anthropic':
        final converted = <Map<String, dynamic>>[];
        for (final m in messages.where((m) => m['role'] != 'system')) {
          final role = m['role'] == 'tool' ? 'user' : m['role'];
          final content = <Map<String, dynamic>>[
            if (m['role'] == 'tool')
              {
                'type': 'tool_result',
                'tool_use_id': m['tool_call_id'],
                'content': m['content'],
              }
            else ...[
              if (m['content'] != null && m['content'] != '')
                {'type': 'text', 'text': m['content']},
              for (final call in m['tool_calls'] as List? ?? [])
                {
                  'type': 'tool_use',
                  'id': call['id'],
                  'name': call['function']['name'],
                  'input': jsonDecode(call['function']['arguments'] as String),
                },
            ],
          ];
          if (content.isEmpty) continue;
          if (converted.isNotEmpty && converted.last['role'] == role) {
            (converted.last['content'] as List).addAll(content);
          } else {
            converted.add({'role': role, 'content': content});
          }
        }
        body.addAll({
          'model': settings.model,
          'stream': stream,
          'max_tokens': 8192,
          'system': messages
              .where((m) => m['role'] == 'system')
              .map((m) => m['content'])
              .join('\n'),
          'messages': converted,
          if (tools.isNotEmpty)
            'tools': [
              for (final tool in tools)
                {
                  'name': tool['function']['name'],
                  'description': tool['function']['description'] ?? '',
                  'input_schema': tool['function']['parameters'],
                },
            ],
        });
      case 'ollama':
        body.addAll({
          'model': settings.model,
          'stream': stream,
          'messages': [
            for (final m in messages)
              {
                ...Map<String, dynamic>.from(m),
                if (m['tool_calls'] is List)
                  'tool_calls': [
                    for (final call in m['tool_calls'] as List)
                      {
                        ...Map<String, dynamic>.from(call as Map),
                        'function': {
                          ...Map<String, dynamic>.from(call['function'] as Map),
                          'arguments': jsonDecode(
                            call['function']['arguments'] as String,
                          ),
                        },
                      },
                  ],
              },
          ],
          if (tools.isNotEmpty) 'tools': tools,
        });
      default:
        body.addAll({...input, 'model': settings.model, 'stream': stream});
        if (!stream) body.remove('stream_options');
        if (RegExp(
          'moonshot|kimi',
          caseSensitive: false,
        ).hasMatch('${settings.llmUrl} ${settings.model}')) {
          body['temperature'] = 1;
        }
    }
    return body;
  }

  Future<Map<String, dynamic>> complete(Map<String, dynamic> input) async {
    final endpoint = roomChatEndpoint(settings.llmUrl);
    final protocol = roomProtocol(endpoint);
    final messages = (input['messages'] as List).cast<Map>();
    final body = _requestBody(input);
    final client = _factory();
    _active.add(client);
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll(roomChatHeaders(settings, endpoint))
        ..body = jsonEncode(body);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 180));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const ApiFailure('Agent 模型返回内容过大');
        }
      }
      if (response.statusCode != 200) {
        final reason = utf8.decode(bytes, allowMalformed: true).toLowerCase();
        if ([400, 422].contains(response.statusCode) &&
            RegExp(r'tool|function').hasMatch(reason) &&
            RegExp(r'unsupported|not support|not allowed|unknown|unexpected')
                .hasMatch(reason)) {
          throw ApiFailure(
            'tools unsupported: 请使用结构化兼容模式',
            status: response.statusCode,
          );
        }
        throw providerFailure('Agent 模型', response.statusCode);
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final reasons = [
        data['stop_reason'],
        for (final choice in data['choices'] as List? ?? [])
          choice['finish_reason'],
      ];
      if (data['error'] != null ||
          ['failed', 'incomplete'].contains(data['status']) ||
          reasons.any(
            (reason) =>
                ['length', 'max_tokens', 'content_filter'].contains(reason),
          )) {
        throw const ApiFailure('Agent 模型回复未完整结束，任务已停止');
      }
      final message = <String, dynamic>{'role': 'assistant', 'content': ''};
      final calls = <Map<String, dynamic>>[];
      if (protocol == 'responses') {
        for (final output in data['output'] as List? ?? []) {
          if (output['type'] == 'function_call') {
            calls.add({
              'id': output['call_id'],
              'type': 'function',
              'function': {
                'name': output['name'],
                'arguments': output['arguments'],
              },
            });
          } else {
            for (final part in output['content'] as List? ?? []) {
              if (part['type'] == 'output_text') {
                message['content'] += part['text'] as String;
              }
            }
          }
        }
      } else if (protocol == 'anthropic') {
        for (final part in data['content'] as List? ?? []) {
          if (part['type'] == 'text') {
            message['content'] += part['text'] as String;
          }
          if (part['type'] == 'tool_use') {
            calls.add({
              'id': part['id'],
              'type': 'function',
              'function': {
                'name': part['name'],
                'arguments': jsonEncode(part['input']),
              },
            });
          }
        }
      } else if (protocol == 'ollama') {
        message['content'] = data['message']?['content'] ?? '';
        var index = 0;
        for (final call in data['message']?['tool_calls'] as List? ?? []) {
          calls.add({
            'id': call['id'] ?? 'call_${messages.length}_${++index}',
            'type': 'function',
            'function': {
              'name': call['function']['name'],
              'arguments': jsonEncode(call['function']['arguments']),
            },
          });
        }
      } else {
        final choices = data['choices'] as List? ?? [];
        if (choices.isEmpty) throw const ApiFailure('Agent 模型没有返回回复');
        message.addAll(
          Map<String, dynamic>.from(choices.first['message'] as Map),
        );
        calls.addAll(
          (message.remove('tool_calls') as List? ?? []).map(
            (c) => Map<String, dynamic>.from(c as Map),
          ),
        );
      }
      if (calls.isNotEmpty) message['tool_calls'] = calls;
      return {
        'id': data['id'] ?? 'chatcmpl-room',
        'object': 'chat.completion',
        'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'model': settings.model,
        'choices': [
          {
            'index': 0,
            'message': message,
            'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
          },
        ],
        'usage': {
          'prompt_tokens': 0,
          'completion_tokens': 0,
          'total_tokens': 0,
        },
      };
    } catch (error) {
      if (error is ApiFailure) lastFailure = error;
      rethrow;
    } finally {
      client.close();
      _active.remove(client);
    }
  }

  Future<void> handle(HttpRequest request, Map<String, dynamic> input) async {
    if (input['stream'] == true &&
        roomProtocol(roomChatEndpoint(settings.llmUrl)) == 'openai') {
      return _forwardOpenAiStream(request, input);
    }
    onProgress?.call(AgentEvent('modelProgress', '正在连接模型'));
    final data = await complete(input);
    onProgress?.call(
      AgentEvent('modelProgress', '模型已返回回复', data: {'activity': true}),
    );
    if (input['stream'] != true) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
    } else {
      request.response.headers.set(
        'Content-Type',
        'text/event-stream; charset=utf-8',
      );
      final choice = (data['choices'] as List).first as Map;
      final message = choice['message'] as Map;
      final chunks = [
        {
          'role': 'assistant',
          'content': message['content'] ?? '',
          if (message['tool_calls'] is List)
            'tool_calls': [
              for (var i = 0; i < (message['tool_calls'] as List).length; i++)
                {
                  'index': i,
                  ...Map<String, dynamic>.from(message['tool_calls'][i] as Map),
                },
            ],
        },
      ];
      for (final delta in chunks) {
        request.response.write(
          'data: ${jsonEncode({
            'id': data['id'],
            'object': 'chat.completion.chunk',
            'created': data['created'],
            'model': data['model'],
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': null},
            ],
          })}\n\n',
        );
      }
      request.response.write(
        'data: ${jsonEncode({
          'id': data['id'],
          'object': 'chat.completion.chunk',
          'created': data['created'],
          'model': data['model'],
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': choice['finish_reason']},
          ],
        })}\n\ndata: [DONE]\n\n',
      );
    }
    await request.response.close();
  }

  Future<void> _forwardOpenAiStream(
    HttpRequest incoming,
    Map<String, dynamic> input,
  ) async {
    final endpoint = roomChatEndpoint(settings.llmUrl), client = _factory();
    _active.add(client);
    var opened = false;
    var expired = false;
    final deadline = Timer(const Duration(seconds: 180), () {
      expired = true;
      client.close();
    });
    String phase = '';
    void progress(Map delta) {
      final next =
          (delta['content'] is String &&
              (delta['content'] as String).isNotEmpty)
          ? 'answer'
          : (delta['reasoning_content'] as String? ?? '').isNotEmpty
          ? 'reasoning'
          : (delta['tool_calls'] as List? ?? []).isNotEmpty
          ? 'tools'
          : '';
      if (next.isEmpty) return;
      onProgress?.call(
        AgentEvent(
          'modelProgress',
          switch (next) {
            'reasoning' => '模型正在整理任务',
            'tools' => '正在准备工具操作',
            _ => '正在生成回复',
          },
          data: {'activity': true, 'phase': next, 'transition': next != phase},
        ),
      );
      phase = next;
    }

    Future<void> write(Map<String, dynamic> chunk) async {
      if (!opened) {
        incoming.response.headers.set(
          'Content-Type',
          'text/event-stream; charset=utf-8',
        );
        incoming.response.headers.set('Cache-Control', 'no-cache');
        incoming.response.bufferOutput = false;
        opened = true;
      }
      incoming.response.write('data: ${jsonEncode(chunk)}\n\n');
      await incoming.response.flush();
    }

    Future<List<int>> read(http.StreamedResponse response) async {
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const ApiFailure('Agent 模型返回内容过大');
        }
      }
      return bytes;
    }

    try {
      onProgress?.call(AgentEvent('modelProgress', '正在连接模型'));
      Future<http.StreamedResponse> send(Map<String, dynamic> body) => client
          .send(
            http.Request('POST', endpoint)
              ..followRedirects = false
              ..headers.addAll(roomChatHeaders(settings, endpoint))
              ..body = jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final body = _requestBody(input, stream: true);
      var response = await send(body);
      if (response.statusCode != 200) {
        final reason = utf8
            .decode(await read(response), allowMalformed: true)
            .toLowerCase();
        if ([400, 422].contains(response.statusCode) &&
            RegExp(r'stream').hasMatch(reason) &&
            RegExp(r'unsupported|not support|not allowed|must be false')
                .hasMatch(reason)) {
          final nonStreaming = {...body, 'stream': false}
            ..remove('stream_options');
          response = await send(nonStreaming);
        } else {
          if ([400, 422].contains(response.statusCode) &&
              RegExp(r'tool|function').hasMatch(reason) &&
              RegExp(r'unsupported|not support|not allowed|unknown|unexpected')
                  .hasMatch(reason)) {
            throw ApiFailure(
              'tools unsupported: 请使用结构化兼容模式',
              status: response.statusCode,
            );
          }
          throw providerFailure('Agent 模型', response.statusCode);
        }
      }
      if (response.statusCode != 200) {
        throw providerFailure('Agent 模型', response.statusCode);
      }
      if (!(response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        final value = jsonDecode(utf8.decode(await read(response))) as Map;
        if (value['error'] != null) throw const ApiFailure('Agent 模型服务返回错误');
        final choice = (value['choices'] as List).first as Map;
        final message = choice['message'] as Map;
        progress(message);
        final calls = message['tool_calls'] as List? ?? [];
        await write({
          'id': value['id'] ?? 'chatcmpl-room',
          'object': 'chat.completion.chunk',
          'model': settings.model,
          'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'choices': [
            {
              'index': 0,
              'delta': {
                ...message,
                if (calls.isNotEmpty)
                  'tool_calls': [
                    for (var i = 0; i < calls.length; i++)
                      {
                        'index': i,
                        ...Map<String, dynamic>.from(calls[i] as Map),
                      },
                  ],
              },
              'finish_reason': null,
            },
          ],
        });
        await write({
          'id': value['id'] ?? 'chatcmpl-room',
          'object': 'chat.completion.chunk',
          'model': settings.model,
          'choices': [
            {
              'index': 0,
              'delta': {},
              'finish_reason':
                  choice['finish_reason'] ??
                  (calls.isEmpty ? 'stop' : 'tool_calls'),
            },
          ],
        });
      } else {
        var size = 0, finished = false;
        final bytes = response.stream.timeout(const Duration(seconds: 45)).map((
          chunk,
        ) {
          size += chunk.length;
          if (size > 2 * 1024 * 1024) throw const ApiFailure('Agent 模型返回内容过大');
          return chunk;
        });
        await for (final chunk in decodeAgentSse(bytes)) {
          if (chunk['agentStreamDone'] == true) break;
          if (chunk['error'] != null) throw const ApiFailure('Agent 模型流式回复失败');
          for (final raw in chunk['choices'] as List? ?? []) {
            final choice = raw as Map;
            if (choice['index'] != null && choice['index'] != 0) continue;
            progress(choice['delta'] as Map? ?? {});
            final finish = choice['finish_reason'];
            if (finish != null) {
              if (!['stop', 'tool_calls', 'function_call'].contains(finish)) {
                throw const ApiFailure('Agent 模型回复未完整结束');
              }
              finished = true;
            }
          }
          await write(chunk);
        }
        if (!finished) throw const ApiFailure('Agent 模型连接中断，回复未完成');
      }
      incoming.response.write('data: [DONE]\n\n');
      await incoming.response.flush();
    } catch (error) {
      final failure = error is ApiFailure
          ? error
          : expired || error is TimeoutException
          ? const ApiFailure('Agent 模型响应超时', status: 504)
          : const ApiFailure('Agent 模型连接或流式协议异常', status: 502);
      lastFailure = failure;
      if (!opened) throw failure;
      try {
        await write({
          'error': {'message': failure.message},
        });
      } catch (_) {
        // Cancellation closes the streaming connection before this error reply.
      }
    } finally {
      deadline.cancel();
      client.close();
      _active.remove(client);
    }
  }
}
