import 'dart:convert';

import 'models.dart';

/// Provider-neutral results. Opaque continuation is request-local, never UI/history.
class ModelLimits {
  const ModelLimits({
    this.textBytes = 262144,
    this.argumentBytes = 32768,
    this.eventBytes = 1048576,
    this.wireBytes = 16 * 1048576,
    this.privateBytes = 262144,
  });
  final int textBytes, argumentBytes, eventBytes, wireBytes, privateBytes;
}

void modelBound(dynamic value, int limit) {
  if (utf8.encode(value is String ? value : jsonEncode(value)).length > limit) {
    throw const ApiFailure('模型协议内容超过安全上限');
  }
}

String modelArgumentKey(dynamic value) {
  dynamic canonical(dynamic item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is List) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value is String ? jsonDecode(value) : value));
}

String modelText(dynamic value) {
  if (value is String) return value;
  if (value is! List) return '';
  return value
      .whereType<Map>()
      .where((p) => ['text', 'output_text'].contains(p['type']))
      .map((p) => p['text'] as String? ?? '')
      .join();
}

void modelStatus(Map data) {
  final reasons = [
    for (final choice in data['choices'] as List? ?? [])
      choice['finish_reason'],
    data['stop_reason'],
    data['done_reason'],
    if (data['delta'] is Map) data['delta']['stop_reason'],
  ];
  if (reasons.any(
        (v) => ['length', 'max_tokens', 'content_filter'].contains(v),
      ) ||
      ['response.incomplete', 'response.failed'].contains(data['type']) ||
      ['incomplete', 'failed'].contains(data['status'])) {
    throw const ModelIncompleteFailure('模型回复未完整结束，请重试');
  }
  // Claude reports policy declines as a normal stop; partial text is not a
  // reply. Not an incomplete reply either: the same wording is declined again.
  if (reasons.contains('refusal')) {
    throw const ApiFailure('模型拒绝了本次请求，回复未保存，请换个说法再试');
  }
  if (data['error'] != null ||
      data['type'] == 'error' ||
      data['success'] == false) {
    throw const ApiFailure('模型服务返回错误，请稍后重试');
  }
}

class ModelCall {
  ModelCall(this.id, this.name, this.arguments, {int maxBytes = 32768}) {
    if (!RegExp(r'^[\w-]{1,160}$').hasMatch(id) ||
        !RegExp(r'^[\w.-]{1,80}$').hasMatch(name)) {
      throw const ApiFailure('模型工具调用标识无效');
    }
    modelBound(arguments, maxBytes);
    if (jsonDecode(arguments) is! Map) throw const ApiFailure('模型工具参数必须是对象');
  }
  final String id, name, arguments;
  Map<String, dynamic> get openAi => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
  };
}

class ModelCompletion {
  ModelCompletion({
    required this.reply,
    this.calls = const [],
    this.items = const [],
    this.protocol = 'openai',
    this.model = '',
    this.usage = const {},
  });
  final String reply, protocol, model;
  final List<ModelCall> calls;
  final List<Map<String, dynamic>> items;
  final Map<String, dynamic> usage;
  Map<String, dynamic> get continuation => {
    'protocol': protocol,
    'items': items,
  };

  factory ModelCompletion.json(
    Map data,
    String protocol, {
    ModelLimits limits = const ModelLimits(),
    bool allowTools = false,
    String callPrefix = 'ollama',
  }) {
    modelBound(data, limits.eventBytes);
    modelStatus(data);
    final calls = <ModelCall>[], items = <Map<String, dynamic>>[];
    String reply = '';
    ModelCall call(dynamic id, dynamic name, dynamic args) => ModelCall(
      id as String? ?? '',
      name as String? ?? '',
      args is String ? args : jsonEncode(args ?? {}),
      maxBytes: limits.argumentBytes,
    );
    if (protocol == 'proxy') {
      reply = data['reply'] as String? ?? '';
      for (final c in data['toolCalls'] as List? ?? []) {
        calls.add(call(c['id'], c['name'], c['arguments']));
      }
      if (data['continuation'] is Map) {
        protocol = data['continuation']['protocol'] as String;
        items.addAll(
          (data['continuation']['items'] as List).map(
            (m) => Map<String, dynamic>.from(m as Map),
          ),
        );
      }
    } else if (protocol == 'responses') {
      for (final raw in data['output'] as List? ?? []) {
        final item = Map<String, dynamic>.from(raw as Map);
        items.add(item);
        if (item['type'] == 'function_call') {
          calls.add(call(item['call_id'], item['name'], item['arguments']));
        }
        if (item['type'] == 'message') reply += modelText(item['content']);
      }
      if (reply.isEmpty) reply = data['output_text'] as String? ?? '';
    } else if (protocol == 'anthropic') {
      // After a server-side fallback only the declined attempt's text is
      // context; its thinking and tool calls must not be echoed back.
      final content = [
        for (final raw in data['content'] as List? ?? [])
          Map<String, dynamic>.from(raw as Map),
      ];
      final cut = content.lastIndexWhere((p) => p['type'] == 'fallback');
      for (final (index, item) in content.indexed) {
        if (index == cut || index < cut && item['type'] != 'text') continue;
        items.add(item);
        if (item['type'] == 'text') reply += item['text'] as String? ?? '';
        if (item['type'] == 'tool_use') {
          calls.add(call(item['id'], item['name'], item['input']));
        }
      }
    } else {
      final choices = (data['choices'] as List? ?? []).whereType<Map>();
      final choice = choices.where((m) => (m['index'] ?? 0) == 0).firstOrNull;
      final message = Map<String, dynamic>.from(
        (choice?['message'] ?? data['message'] ?? {}) as Map,
      );
      reply = modelText(message['content']);
      if (reply.isEmpty) {
        reply = data['response'] as String? ?? choice?['text'] as String? ?? '';
      }
      var index = 0;
      for (final c in message['tool_calls'] as List? ?? []) {
        calls.add(
          call(
            c['id'] ?? (protocol == 'ollama' ? '${callPrefix}_${index++}' : ''),
            c['function']?['name'],
            c['function']?['arguments'],
          ),
        );
      }
      if (calls.isNotEmpty) {
        items.add({
          'role': 'assistant',
          'content': reply.isEmpty ? null : reply,
          if (message['reasoning_content'] is String)
            'reasoning_content': message['reasoning_content'],
          if (protocol == 'ollama' && message['thinking'] is String)
            'thinking': message['thinking'],
          'tool_calls': calls.map((c) => c.openAi).toList(),
        });
      }
    }
    // Existing site-compatible gateways may wrap visible text in these fields.
    if (data['reply'] is String) {
      reply = data['reply'] as String;
    } else if (data['output_text'] is String) {
      reply = data['output_text'] as String;
    }
    if (calls.length > 6 ||
        calls.map((c) => c.id).toSet().length != calls.length) {
      throw const ApiFailure('模型工具调用数量或标识无效');
    }
    if (calls.isNotEmpty && !allowTools) {
      throw const ModelIncompleteFailure('模型请求了未启用的工具');
    }
    modelBound(reply, limits.textBytes);
    if (reply.isEmpty && calls.isEmpty) {
      throw const ModelIncompleteFailure('模型没有返回可用回复');
    }
    if (items.length > 32) throw const ApiFailure('模型续接上下文过多');
    for (final item in items) {
      for (final key in [
        'reasoning_content',
        'thinking',
        'signature',
        'encrypted_content',
      ]) {
        if (item[key] is String) modelBound(item[key], limits.privateBytes);
      }
    }
    final usage = data['usage'] is Map
        ? Map<String, dynamic>.from(data['usage'])
        : {
            if (data['eval_count'] is num)
              'completion_tokens': data['eval_count'],
            if (data['prompt_eval_count'] is num)
              'prompt_tokens': data['prompt_eval_count'],
          };
    return ModelCompletion(
      reply: reply,
      calls: calls,
      items: calls.isEmpty ? [] : items,
      protocol: protocol,
      usage: usage,
      model: data['model'] as String? ?? '',
    );
  }
}

class ModelWireEvent {
  const ModelWireEvent(this.type, {this.text = '', this.completion});
  final String type, text;
  final ModelCompletion? completion;
}

class WireFrame {
  const WireFrame(this.data, this.event);
  final String data, event;
}

/// Line and event boundaries follow deepseek-ai/chat-demo's SSE decoder.
/// NDJSON accepts a final line without a newline. SSE requires a blank line.
Stream<WireFrame> modelFrames(
  Stream<List<int>> source, {
  bool ndjson = false,
  int eventBytes = 1048576,
  int wireBytes = 16 * 1048576,
}) async* {
  var wire = 0;
  Stream<List<int>> slices() async* {
    await for (final bytes in source) {
      wire += bytes.length;
      if (wire > wireBytes) throw const ApiFailure('模型传输超过安全上限');
      for (var i = 0; i < bytes.length; i += 16384) {
        yield bytes.sublist(i, (i + 16384).clamp(0, bytes.length));
      }
    }
  }

  final line = StringBuffer();
  final data = <String>[];
  var event = 'message', size = 0, skipLF = false;
  void append(String part) {
    size += utf8.encode(part).length;
    if (size > eventBytes) throw const ApiFailure('模型协议内容超过安全上限');
    line.write(part);
  }

  await for (final chunk in slices().transform(utf8.decoder)) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk.codeUnitAt(i);
      if (skipLF) {
        skipLF = false;
        if (ch == 10) {
          start = i + 1;
          continue;
        }
      }
      if (ch != 13 && ch != 10) continue;
      size++;
      append(chunk.substring(start, i));
      final current = line.toString();
      line.clear();
      start = i + 1;
      skipLF = ch == 13;
      if (ndjson || current.isEmpty) {
        if (ndjson && current.trim().isNotEmpty) {
          yield WireFrame(current.trim(), 'message');
        } else if (data.isNotEmpty) {
          yield WireFrame(data.join('\n'), event);
        }
        data.clear();
        event = 'message';
        size = 0;
      } else {
        final colon = current.indexOf(':');
        final field = colon < 0 ? current : current.substring(0, colon);
        var value = colon < 0 ? '' : current.substring(colon + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        if (field == 'data') data.add(value);
        if (field == 'event') event = value.isEmpty ? 'message' : value;
      }
    }
    append(chunk.substring(start));
  }
  if (ndjson && line.toString().trim().isNotEmpty) {
    yield WireFrame(line.toString().trim(), 'message');
  }
}

/// Checks only new UTF-8 content instead of re-encoding the entire reply/tool
/// input for every token. Surrogates split across JSON deltas count as one pair.
class _WireText {
  final _parts = StringBuffer();
  int _bytes = 0, _lastUnit = -1;
  void add(String value, int limit) {
    if (value.isEmpty) return;
    var bytes = utf8.encode(value).length;
    final first = value.codeUnitAt(0);
    if (_lastUnit >= 0xd800 &&
        _lastUnit <= 0xdbff &&
        first >= 0xdc00 &&
        first <= 0xdfff) {
      bytes -= 2;
    }
    _bytes += bytes;
    if (_bytes > limit) throw const ApiFailure('模型协议内容超过安全上限');
    _parts.write(value);
    _lastUnit = value.codeUnitAt(value.length - 1);
  }

  @override
  String toString() => _parts.toString();
}

Map<String, dynamic> _wireStrings(Map value) => {
  for (final entry in value.entries)
    entry.key as String: entry.value is _WireText
        ? entry.value.toString()
        : entry.value,
};

void _appendWire(Map target, String key, String value, int limit) {
  final old = target[key];
  final buffer = old is _WireText
      ? old
      : (_WireText()..add('${old ?? ''}', limit));
  buffer.add(value, limit);
  target[key] = buffer;
}

class _ModelDecoder {
  _ModelDecoder(this.protocol, this.limits, this.allowTools, this.callPrefix);
  final String protocol, callPrefix;
  final ModelLimits limits;
  final bool allowTools;
  bool completed = false, terminal = false;
  final _reply = _WireText(), _reasoning = _WireText();
  String get reply => _reply.toString();
  String get reasoning => _reasoning.toString();
  String model = '';
  final usage = <String, dynamic>{},
      calls = <int, Map<String, dynamic>>{},
      blocks = <int, Map<String, dynamic>>{};
  final output = <int, Map<String, dynamic>>{};
  ModelCompletion? finalValue;
  List<ModelWireEvent> consume(WireFrame frame) {
    if (frame.data == '[DONE]') {
      completed = terminal = true;
      return [];
    }
    final p = jsonDecode(frame.data) as Map;
    modelStatus(p);
    if (frame.event == 'error') throw const ApiFailure('模型流式服务返回错误');
    model =
        p['model'] as String? ??
        p['message']?['model'] as String? ??
        p['response']?['model'] as String? ??
        model;
    if (p['usage'] is Map) usage.addAll(Map<String, dynamic>.from(p['usage']));
    final events = <ModelWireEvent>[];
    void text(String value) {
      if (value.isEmpty) return;
      _reply.add(value, limits.textBytes);
      events.add(ModelWireEvent('text', text: value));
    }

    void activity(String phase) =>
        events.add(ModelWireEvent('activity', text: phase));
    switch (protocol) {
      case 'proxy':
        if (frame.event == 'delta') text(p['text'] as String? ?? '');
        if (frame.event == 'done') {
          finalValue = ModelCompletion.json(
            p,
            protocol,
            limits: limits,
            allowTools: allowTools,
          );
          completed = terminal = true;
        }
      case 'responses':
        final type = p['type'] ?? frame.event;
        if (type == 'response.output_text.delta') {
          text(p['delta'] as String? ?? '');
        }
        if (type == 'response.reasoning_summary_text.delta' ||
            type == 'response.reasoning_text.delta') {
          activity('reasoning');
        }
        if (type == 'response.output_item.added' ||
            type == 'response.output_item.done') {
          if (p['item'] is Map) {
            output[p['output_index'] as int? ?? output.length] =
                Map<String, dynamic>.from(p['item']);
          }
          if (p['item']?['type'] == 'function_call') activity('tools');
        }
        if (type == 'response.function_call_arguments.delta') {
          final item = output[p['output_index'] as int? ?? 0];
          if (item == null) throw const ApiFailure('模型工具参数没有对应输出项');
          _appendWire(
            item,
            'arguments',
            '${p['delta'] ?? ''}',
            limits.argumentBytes,
          );
          activity('tools');
        }
        if (type == 'response.completed') {
          final data = Map<String, dynamic>.from((p['response'] ?? p) as Map);
          modelStatus(data);
          if ((data['output'] as List? ?? []).isEmpty && output.isNotEmpty) {
            data['output'] = output.values.map(_wireStrings).toList();
          }
          if ((data['output'] as List? ?? []).isEmpty && reply.isNotEmpty) {
            data['output_text'] = reply;
          }
          finalValue = ModelCompletion.json(
            data,
            protocol,
            limits: limits,
            allowTools: allowTools,
          );
          completed = terminal = true;
        }
      case 'anthropic':
        if (p['type'] == 'message_start' && p['message']?['usage'] is Map) {
          usage.addAll(Map<String, dynamic>.from(p['message']['usage']));
        }
        if (p['type'] == 'content_block_start') {
          final block = Map<String, dynamic>.from(p['content_block'] as Map);
          blocks[p['index'] as int] = block;
          if (block['type'] == 'text') text(block['text'] as String? ?? '');
        }
        if (p['type'] == 'content_block_delta') {
          final delta = p['delta'] as Map, block = blocks[p['index']];
          switch (delta['type']) {
            case 'text_delta':
              text(delta['text'] as String? ?? '');
              if (block != null) {
                _appendWire(
                  block,
                  'text',
                  '${delta['text'] ?? ''}',
                  limits.textBytes,
                );
              }
            case 'input_json_delta':
              if (block == null) throw const ApiFailure('模型工具参数没有对应内容块');
              _appendWire(
                block,
                'partial',
                '${delta['partial_json'] ?? ''}',
                limits.argumentBytes,
              );
              activity('tools');
            case 'thinking_delta':
            case 'signature_delta':
              final key = delta['type'] == 'thinking_delta'
                  ? 'thinking'
                  : 'signature';
              if (block != null) {
                _appendWire(
                  block,
                  key,
                  '${delta[key] ?? ''}',
                  limits.privateBytes,
                );
              }
              activity('reasoning');
          }
        }
        if (p['type'] == 'message_stop' || frame.event == 'message_stop') {
          completed = terminal = true;
        }
      case 'ollama':
        text(modelText(p['message']?['content'] ?? p['response']));
        if (p['message']?['thinking'] is String) {
          _reasoning.add(
            p['message']['thinking'] as String,
            limits.privateBytes,
          );
          activity('reasoning');
        }
        if (p['message']?['tool_calls'] is List) {
          for (final raw in p['message']['tool_calls']) {
            if (calls.length >= 6) throw const ApiFailure('模型工具调用数量无效');
            calls[calls.length] = Map<String, dynamic>.from(raw as Map);
          }
          activity('tools');
        }
        if (p['done'] == true) {
          completed = terminal = true;
          if (p['eval_count'] is num) {
            usage['completion_tokens'] = p['eval_count'];
          }
          if (p['prompt_eval_count'] is num) {
            usage['prompt_tokens'] = p['prompt_eval_count'];
          }
        }
      default:
        final choice = (p['choices'] as List? ?? [])
            .whereType<Map>()
            .where((c) => (c['index'] ?? 0) == 0)
            .firstOrNull;
        final delta = choice?['delta'] as Map? ?? {};
        text(modelText(delta['content'] ?? delta['text']));
        if (delta['reasoning_content'] is String) {
          _reasoning.add(
            delta['reasoning_content'] as String,
            limits.privateBytes,
          );
          activity('reasoning');
        }
        var i = 0;
        for (final call in delta['tool_calls'] as List? ?? []) {
          final index = call['index'] as int? ?? i++;
          if (index < 0 || index >= 6) throw const ApiFailure('模型工具调用数量无效');
          final old = calls.putIfAbsent(
            index,
            () => {
              'id': '',
              'function': <String, dynamic>{'name': '', 'arguments': ''},
            },
          );
          if (call['id'] != null) {
            if ((old['id'] as String).isNotEmpty && old['id'] != call['id']) {
              throw const ApiFailure('模型工具调用标识在流中发生变化');
            }
            old['id'] = call['id'];
          }
          final f = old['function'] as Map,
              update = call['function'] as Map? ?? {};
          if (update['name'] != f['name'].toString()) {
            _appendWire(f, 'name', '${update['name'] ?? ''}', 80);
          }
          _appendWire(
            f,
            'arguments',
            '${update['arguments'] ?? ''}',
            limits.argumentBytes,
          );
          activity('tools');
        }
        if (choice?['usage'] is Map) {
          usage.addAll(Map<String, dynamic>.from(choice!['usage']));
        }
        if (choice?['finish_reason'] != null) completed = true;
    }
    if (calls.length > 6 || blocks.length > 32 || output.length > 32) {
      throw const ApiFailure('模型协议内容块过多');
    }
    return events;
  }

  ModelCompletion finish() {
    if (!completed) throw const ModelStreamInterrupted('连接中断，未完成的回复没有保存');
    var value = finalValue;
    if (value == null) {
      final data = <String, dynamic>{'model': model, 'usage': usage};
      if (protocol == 'anthropic') {
        // A declined attempt can stop mid tool input; the JSON decoder drops
        // blocks before the last fallback, so their partial input is not parsed.
        final ordered = blocks.values.toList();
        final cut = ordered.lastIndexWhere((b) => b['type'] == 'fallback');
        data['content'] = ordered.indexed.map((entry) {
          final (index, block) = entry;
          final item = _wireStrings(block);
          final partial = item.remove('partial');
          if (index > cut && partial is String && partial.isNotEmpty) {
            item['input'] = jsonDecode(partial);
          }
          return item;
        }).toList();
        if (blocks.isEmpty && reply.isNotEmpty) {
          data['content'] = [
            {'type': 'text', 'text': reply},
          ];
        }
      } else {
        data['message'] = {
          'role': 'assistant',
          'content': reply,
          if (reasoning.isNotEmpty)
            (protocol == 'ollama' ? 'thinking' : 'reasoning_content'):
                reasoning,
          if (calls.isNotEmpty)
            'tool_calls': [
              for (final call in calls.values)
                {
                  ...call,
                  if (call['function'] is Map)
                    'function': _wireStrings(call['function'] as Map),
                },
            ],
        };
      }
      value = ModelCompletion.json(
        data,
        protocol,
        limits: limits,
        allowTools: allowTools,
        callPrefix: callPrefix,
      );
    }
    return ModelCompletion(
      reply: value.reply.isEmpty ? reply : value.reply,
      calls: value.calls,
      items: value.items,
      protocol: value.protocol,
      model: value.model.isEmpty ? model : value.model,
      usage: {...value.usage, ...usage},
    );
  }
}

Stream<ModelWireEvent> decodeModelStream(
  Stream<List<int>> bytes,
  String protocol, {
  ModelLimits limits = const ModelLimits(),
  bool allowTools = false,
  String callPrefix = 'ollama',
}) async* {
  final decoder = _ModelDecoder(protocol, limits, allowTools, callPrefix);
  await for (final frame in modelFrames(
    bytes,
    ndjson: protocol == 'ollama',
    eventBytes: limits.eventBytes,
    wireBytes: limits.wireBytes,
  )) {
    for (final event in decoder.consume(frame)) {
      yield event;
    }
    if (decoder.terminal) break;
  }
  final value = decoder.finish();
  if (decoder.reply.isEmpty && value.reply.isNotEmpty) {
    yield ModelWireEvent('text', text: value.reply);
  }
  yield ModelWireEvent('complete', completion: value);
}

/// Exact call/result pairs, including opaque provider state, are replayed once.
Map<String, dynamic> modelWithTools(
  Map<String, dynamic> payload,
  String protocol,
  List<Map<String, dynamic>> tools,
  List<Map<String, dynamic>> turns,
) {
  final body = Map<String, dynamic>.from(payload);
  modelBound(turns, 8 * 1048576);
  for (final turn in turns) {
    final state = turn['continuation'] as Map;
    if (state['protocol'] != protocol) throw const ApiFailure('模型续接协议不匹配');
    final items = (state['items'] as List).cast<Map>();
    final calls = protocol == 'responses'
        ? items
              .where((p) => p['type'] == 'function_call')
              .map((p) => (p['call_id'], p['name']))
        : protocol == 'anthropic'
        ? items
              .where((p) => p['type'] == 'tool_use')
              .map((p) => (p['id'], p['name']))
        : items
              .expand((p) => p['tool_calls'] as List? ?? [])
              .map((p) => (p['id'], p['function']?['name']));
    final results = (turn['results'] as List).cast<Map>();
    if (calls.isEmpty ||
        results.any((r) => r['content'] is! String || r['isError'] is! bool) ||
        calls.length != results.length ||
        calls.map((c) => c.$1).toSet().length != calls.length ||
        results.map((r) => r['id']).toSet().length != results.length ||
        calls.any(
          (c) => !results.any((r) => r['id'] == c.$1 && r['name'] == c.$2),
        )) {
      throw const ApiFailure('模型工具调用与结果不匹配');
    }
  }
  if (protocol == 'responses') {
    body['store'] = false;
    body['input'] = [
      ...payload['input'] as List,
      for (final turn in turns) ...[
        ...turn['continuation']['items'] as List,
        for (final r in turn['results'])
          {
            'type': 'function_call_output',
            'call_id': r['id'],
            'output': r['content'],
          },
      ],
    ];
    if (tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => {
              'type': 'function',
              'name': t['name'],
              'description': t['description'],
              'parameters': t['inputSchema'],
              'strict': false,
            },
          )
          .toList();
    }
  } else if (protocol == 'anthropic') {
    body['messages'] = [
      ...payload['messages'] as List,
      for (final turn in turns) ...[
        {'role': 'assistant', 'content': turn['continuation']['items']},
        {
          'role': 'user',
          'content': [
            for (final r in turn['results'])
              {
                'type': 'tool_result',
                'tool_use_id': r['id'],
                'content': r['content'],
                'is_error': r['isError'],
              },
          ],
        },
      ],
    ];
    if (tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => {
              'name': t['name'],
              'description': t['description'],
              'input_schema': t['inputSchema'],
            },
          )
          .toList();
    }
  } else {
    body['messages'] = [...payload['messages'] as List];
    if (turns.isNotEmpty && body['preserve_thinking'] == false) {
      body['preserve_thinking'] = true;
    }
    for (final turn in turns) {
      for (final raw in turn['continuation']['items']) {
        final item = Map<String, dynamic>.from(raw as Map);
        if (protocol == 'ollama' && item['tool_calls'] is List) {
          item['tool_calls'] = [
            for (final call in item['tool_calls'])
              {
                'function': {
                  'name': call['function']['name'],
                  'arguments': jsonDecode(
                    call['function']['arguments'] as String,
                  ),
                },
              },
          ];
        }
        (body['messages'] as List).add(item);
      }
      for (final r in turn['results']) {
        (body['messages'] as List).add({
          'role': 'tool',
          if (protocol == 'ollama')
            'tool_name': r['name']
          else
            'tool_call_id': r['id'],
          'content': r['content'],
        });
      }
    }
    if (tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => {
              'type': 'function',
              'function': {
                'name': t['name'],
                'description': t['description'],
                'parameters': t['inputSchema'],
              },
            },
          )
          .toList();
    }
  }
  return body;
}
