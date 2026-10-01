import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';
import '../room_protocol.dart';

/// Keeps Room's exact endpoints/headers/keys out of the sidecar configuration.
/// OpenCode sees an OpenAI-compatible API; all four Room protocols retain tools.
class AgentProviderBridge {
  AgentProviderBridge(this.settings, {http.Client Function()? clientFactory})
    : _factory = clientFactory ?? http.Client.new;
  final RoomSettings settings;
  final http.Client Function() _factory;
  final _active = <http.Client>{};
  ApiFailure? lastFailure;
  void clearFailure() => lastFailure = null;
  void cancel() {
    for (final client in _active) {
      client.close();
    }
    _active.clear();
  }

  Future<Map<String, dynamic>> complete(Map<String, dynamic> input) async {
    final endpoint = roomChatEndpoint(settings.llmUrl);
    final protocol = roomProtocol(endpoint);
    final messages = (input['messages'] as List).cast<Map>();
    final tools = (input['tools'] as List? ?? []).cast<Map>();
    final body = <String, dynamic>{};
    switch (protocol) {
      case 'responses':
        body.addAll({
          'model': settings.model,
          'stream': false,
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
          'stream': false,
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
          'stream': false,
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
        body.addAll({...input, 'model': settings.model, 'stream': false});
        body.remove('stream_options');
        if (RegExp(
          'moonshot|kimi',
          caseSensitive: false,
        ).hasMatch('${settings.llmUrl} ${settings.model}')) {
          body['temperature'] = 1;
        }
    }
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
    final data = await complete(input);
    if (input['stream'] != true) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
    } else {
      request.response.headers.set('Content-Type', 'text/event-stream');
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
}
