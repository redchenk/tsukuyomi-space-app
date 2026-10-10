import 'models.dart';
import 'room_protocol.dart' show roomChatEndpoint, roomProtocol;

const modelParameterLabels = {
  'temperature': '温度',
  'topP': 'Top P',
  'maxOutputTokens': '最大输出 Token',
  'reasoningEffort': '推理强度',
  'reasoningEnabled': '思考模式',
};
const modelCapabilityLabels = {
  'text': '文本对话',
  'image': '图片输入',
  'tools': '工具调用',
  'streaming': '流式输出',
};
const _fields = {
  'temperature': ['temperature', 'options.temperature'],
  'topP': ['top_p', 'options.top_p'],
  'maxOutputTokens': [
    'max_tokens',
    'max_completion_tokens',
    'max_output_tokens',
    'options.num_predict',
  ],
  'reasoningEffort': ['reasoning_effort', 'reasoning.effort'],
  'reasoningEnabled': ['think', 'enable_thinking'],
};

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
Map<String, bool> _capabilities(dynamic input) => {
  for (final key in modelCapabilityLabels.keys)
    if (input is Map && input[key] is bool) key: input[key] as bool,
};
Never _invalid(String text) => throw ApiFailure(text, status: 400);

Map<String, dynamic> normalizeModelRuntime(dynamic input) {
  final result = <String, dynamic>{
    'version': 1,
    'providers': {},
    'models': {},
    'declarations': {},
  };
  if (input == null) return result;
  if (input is! Map || (input['version'] != null && input['version'] != 1)) {
    _invalid('模型配置版本无效');
  }
  for (final group in ['providers', 'models', 'declarations']) {
    final entries = input[group] ?? {};
    if (entries is! Map || entries.length > 64) _invalid('模型配置条目过多或格式无效');
    for (final entry in entries.entries) {
      final key = entry.key;
      if (key is! String ||
          key.isEmpty ||
          key.length > 640 ||
          RegExp(r'[\x00-\x1f]').hasMatch(key) ||
          ['__proto__', 'constructor', 'prototype'].contains(key)) {
        _invalid('模型配置标识无效');
      }
      if (group == 'declarations') {
        (result[group] as Map)[key] = _capabilities(entry.value);
        continue;
      }
      if (entry.value is! Map) _invalid('模型配置格式无效');
      final layer = _map(entry.value),
          parameters = _map(layer['parameters']),
          mappings = _map(layer['mappings']);
      final values = <String, dynamic>{}, paths = <String, String>{};
      for (final name in _fields.keys) {
        final value = parameters[name];
        if (value != null && value != '') {
          final valid = switch (name) {
            'reasoningEffort' => ['low', 'medium', 'high'].contains(value),
            'reasoningEnabled' => value is bool,
            'temperature' =>
              value is num && value.isFinite && value >= 0 && value <= 2,
            'topP' =>
              value is num && value.isFinite && value >= .001 && value <= 1,
            _ =>
              value is num &&
                  value.isFinite &&
                  value >= 16 &&
                  value <= 131072 &&
                  value == value.truncate(),
          };
          if (!valid) _invalid('${modelParameterLabels[name]}的值无效');
          values[name] = value;
        }
        final field = mappings[name];
        if (field != null && field != '' && field != 'inherit') {
          if (field != 'omit' && !_fields[name]!.contains(field)) {
            _invalid('${modelParameterLabels[name]}的映射字段无效');
          }
          paths[name] = field as String;
        }
      }
      (result[group] as Map)[key] = {
        'parameters': values,
        'mappings': paths,
        'capabilities': _capabilities(layer['capabilities']),
      };
    }
  }
  return result;
}

class ModelRuntime {
  ModelRuntime(this.settings)
    : config = normalizeModelRuntime(settings.options['runtimeConfig']);
  final RoomSettings settings;
  final Map<String, dynamic> config;
  Uri get endpoint => roomChatEndpoint(settings.llmUrl);
  String get protocol => roomProtocol(endpoint);
  String get providerKey =>
      '${endpoint.origin}${endpoint.path.replaceFirst(RegExp(r'/$'), '')}';
  String get modelKey => '$providerKey#${settings.model.trim()}';
  Map<String, dynamic> get provider =>
      _map(_map(config['providers'])[providerKey]);
  Map<String, dynamic> get model => _map(_map(config['models'])[modelKey]);

  List<String> allowedMappings(String name) => [
    'inherit',
    'omit',
    ..._fields[name]!.where(
      (field) => switch (protocol) {
        'ollama' => field.startsWith('options.') || field == 'think',
        'responses' => [
          'temperature',
          'top_p',
          'max_output_tokens',
          'reasoning.effort',
        ].contains(field),
        'anthropic' => ['temperature', 'top_p', 'max_tokens'].contains(field),
        _ =>
          !field.startsWith('options.') &&
              ![
                'max_output_tokens',
                'reasoning.effort',
                'think',
              ].contains(field),
      },
    ),
  ];

  Map<String, String> get defaultMappings {
    final reasoning = RegExp(
      r'^(?:o[1-9](?:-|$)|gpt-(?:[5-9]|[1-9]\d)(?:[.-]|$))',
      caseSensitive: false,
    ).hasMatch(settings.model.split('/').last);
    if (protocol == 'ollama') {
      return {
        'temperature': 'options.temperature',
        'topP': 'options.top_p',
        'maxOutputTokens': 'options.num_predict',
        'reasoningEffort': 'omit',
        'reasoningEnabled': 'think',
      };
    }
    if (protocol == 'responses') {
      return {
        'temperature': reasoning ? 'omit' : 'temperature',
        'topP': reasoning ? 'omit' : 'top_p',
        'maxOutputTokens': 'max_output_tokens',
        'reasoningEffort': 'reasoning.effort',
        'reasoningEnabled': 'omit',
      };
    }
    if (protocol == 'anthropic') {
      return {
        'temperature': 'temperature',
        'topP': 'top_p',
        'maxOutputTokens': 'max_tokens',
        'reasoningEffort': 'omit',
        'reasoningEnabled': 'omit',
      };
    }
    final qwen = RegExp(r'^dashscope(?:-intl|-us)?\.aliyuncs\.com$')
        .hasMatch(endpoint.host);
    return {
      'temperature': reasoning ? 'omit' : 'temperature',
      'topP': reasoning ? 'omit' : 'top_p',
      'maxOutputTokens': reasoning ? 'max_completion_tokens' : 'max_tokens',
      'reasoningEffort': 'reasoning_effort',
      'reasoningEnabled': qwen ? 'enable_thinking' : 'omit',
    };
  }

  Map<String, dynamic> resolveParameters() => {
    for (final name in _fields.keys) name: _resolveParameter(name),
  };
  Map<String, dynamic> _resolveParameter(String name) {
    final modelValue = _map(model['parameters'])[name],
        providerValue = _map(provider['parameters'])[name];
    final field =
        _map(model['mappings'])[name] ??
        _map(provider['mappings'])[name] ??
        defaultMappings[name];
    if (!allowedMappings(name).contains(field)) {
      _invalid('${modelParameterLabels[name]}的映射不适用于当前协议');
    }
    if (protocol == 'anthropic' &&
        name == 'maxOutputTokens' &&
        field == 'omit') {
      _invalid('Messages 协议必须发送最大输出 Token');
    }
    return {
      'field': field,
      if ((modelValue ?? providerValue) != null)
        'value': modelValue ?? providerValue,
      'valueSource': modelValue != null
          ? 'model'
          : providerValue != null
          ? 'provider'
          : 'builtin',
      'mappingSource': _map(model['mappings']).containsKey(name)
          ? 'model'
          : _map(provider['mappings']).containsKey(name)
          ? 'provider'
          : 'builtin',
    };
  }

  Map<String, dynamic> resolveCapabilities() {
    final builtin = <String, bool>{};
    if (endpoint.host == 'api.openai.com' &&
        RegExp(
          r'^gpt-4o(?:-mini)?(?:-\d{4}-\d{2}-\d{2})?$',
          caseSensitive: false,
        ).hasMatch(settings.model)) {
      builtin.addAll({
        'text': true,
        'image': true,
        'tools': true,
        'streaming': true,
      });
    }
    if (endpoint.host == 'api.minimaxi.com' && protocol == 'anthropic') {
      builtin['image'] = false;
    }
    final remote = _capabilities(_map(config['declarations'])[modelKey]),
        manual = _capabilities(model['capabilities']);
    return {
      for (final key in modelCapabilityLabels.keys)
        key: {
          'value': manual[key] ?? remote[key] ?? builtin[key],
          'source': manual.containsKey(key)
              ? 'manual'
              : remote.containsKey(key)
              ? 'provider'
              : builtin.containsKey(key)
              ? 'builtin'
              : 'unknown',
          'declared': remote[key],
          'builtin': builtin[key],
        },
    };
  }

  bool unsupported(String capability) =>
      resolveCapabilities()[capability]?['value'] == false;
  void require(String capability) {
    if (unsupported(capability)) {
      _invalid('当前模型声明不支持${modelCapabilityLabels[capability]}，请更换模型或调整能力覆盖');
    }
  }

  Map<String, dynamic> transport() => {
    'version': 1,
    'providers': {
      if (_map(config['providers']).containsKey(providerKey))
        providerKey: config['providers'][providerKey],
    },
    'models': {
      if (_map(config['models']).containsKey(modelKey))
        modelKey: config['models'][modelKey],
    },
    'declarations': {
      if (_map(config['declarations']).containsKey(modelKey))
        modelKey: config['declarations'][modelKey],
    },
  };
  Map<String, dynamic> apply(Map<String, dynamic> payload) {
    final result = <String, dynamic>{
      ...payload,
      if (payload['options'] is Map) 'options': _map(payload['options']),
      if (payload['reasoning'] is Map) 'reasoning': _map(payload['reasoning']),
    };
    dynamic read(String path) {
      dynamic current = result;
      for (final part in path.split('.')) {
        current = current is Map ? current[part] : null;
      }
      return current;
    }

    for (final entry in resolveParameters().entries) {
      final fields = _fields[entry.key]!, item = entry.value as Map;
      final existing = fields.map(read).where((v) => v != null).firstOrNull;
      final value = item['value'] ?? existing;
      for (final field in fields) {
        final parts = field.split('.');
        if (parts.length == 1) {
          result.remove(field);
        } else if (result[parts.first] is Map) {
          (result[parts.first] as Map).remove(parts.last);
        }
      }
      if (item['field'] != 'omit' && value != null) {
        final parts = (item['field'] as String).split('.');
        if (parts.length == 1) {
          result[parts.first] = value;
        } else {
          result.putIfAbsent(parts.first, () => <String, dynamic>{});
          (result[parts.first] as Map)[parts.last] = value;
        }
      }
    }
    return result;
  }
}
