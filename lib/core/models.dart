import 'dart:math';

Uri endpointUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !['https', 'http'].contains(uri.scheme)) {
    throw const FormatException('请输入完整的 HTTPS 地址');
  }
  if (uri.scheme == 'http' &&
      ![
        'localhost',
        '127.0.0.1',
        '::1',
        '[::1]',
        '10.0.2.2',
      ].contains(uri.host)) {
    throw const FormatException('HTTP 仅用于本机开发；远程服务请使用 HTTPS');
  }
  return uri;
}

/// Accept either a provider base URL or the complete OpenAI-compatible route.
Uri compatibleEndpoint(String value, {bool speech = false}) {
  final uri = endpointUri(value);
  var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  final suffix = speech ? '/audio/speech' : '/chat/completions';
  if (path.endsWith(suffix)) return uri.replace(path: path);
  if (path.endsWith('/responses') ||
      path.endsWith(speech ? '/chat/completions' : '/audio/speech')) {
    throw FormatException(
      '请填写${speech ? 'Speech' : 'Chat Completions'} 地址或服务 Base URL',
    );
  }
  if (path.isEmpty) path = '/v1';
  return uri.replace(path: '$path$suffix');
}

ApiFailure providerFailure(String service, int status) {
  final detail = switch (status) {
    401 || 403 => '请检查 API Key 和该模型的访问权限',
    404 => '接口或模型不存在，请检查地址和模型名',
    400 || 422 => '服务不接受当前参数，请检查模型、音色或音频格式',
    429 => '请求受限或额度不足，请检查服务额度后重试',
    >= 500 => '服务暂时不可用，请稍后重试',
    >= 300 && < 400 => '接口发生重定向，请直接填写最终 HTTPS 地址',
    _ => '请检查服务配置后重试',
  };
  return ApiFailure('$service失败（HTTP $status）：$detail', status: status);
}

String newTurnId() {
  final random = Random.secure();
  return 'app-${DateTime.now().microsecondsSinceEpoch}-${List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

class RoomSettings {
  const RoomSettings({
    this.siteUrl = 'https://yachiyo.hk',
    this.llmUrl = 'http://localhost:11434/v1/chat/completions',
    this.model = '',
    this.apiKey = '',
    this.ttsUrl = '',
    this.ttsKey = '',
    this.ttsModel = 'tts-1',
    this.voice = 'alloy',
    this.ttsFormat = 'wav',
    this.demo = false,
    this.speak = false,
    this.options = const {},
    this.mcpKey = '',
  });
  final String siteUrl, llmUrl, model, apiKey, ttsUrl, ttsKey, ttsModel, voice;
  final String ttsFormat;
  final bool demo, speak;

  /// Additional Room settings. Secrets stay in system secure storage.
  final Map<String, dynamic> options;
  final String mcpKey;
  bool flag(String key, [bool fallback = false]) =>
      options[key] as bool? ?? fallback;
  String option(String key, [String fallback = '']) =>
      options[key]?.toString() ?? fallback;
  double number(String key, [double fallback = 0]) =>
      (options[key] as num?)?.toDouble() ?? fallback;
  List<Map<String, dynamic>> rows(String key) => (options[key] as List? ?? [])
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  RoomSettings copyWith({
    String? siteUrl,
    String? llmUrl,
    String? model,
    String? apiKey,
    String? ttsUrl,
    String? ttsKey,
    String? ttsModel,
    String? voice,
    String? ttsFormat,
    bool? demo,
    bool? speak,
    Map<String, dynamic>? options,
    String? mcpKey,
  }) => RoomSettings(
    siteUrl: siteUrl ?? this.siteUrl,
    llmUrl: llmUrl ?? this.llmUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    ttsUrl: ttsUrl ?? this.ttsUrl,
    ttsKey: ttsKey ?? this.ttsKey,
    ttsModel: ttsModel ?? this.ttsModel,
    voice: voice ?? this.voice,
    ttsFormat: ttsFormat ?? this.ttsFormat,
    demo: demo ?? this.demo,
    speak: speak ?? this.speak,
    options: options ?? this.options,
    mcpKey: mcpKey ?? this.mcpKey,
  );

  Map<String, dynamic> toJson() => {
    'siteUrl': siteUrl,
    'llmUrl': llmUrl,
    'model': model,
    'ttsUrl': ttsUrl,
    'ttsModel': ttsModel,
    'voice': voice,
    'ttsFormat': ttsFormat,
    'demo': demo,
    'speak': speak,
    'options': options,
  };
  factory RoomSettings.fromJson(
    Map<String, dynamic> j, {
    String apiKey = '',
    String ttsKey = '',
    String mcpKey = '',
  }) => RoomSettings(
    siteUrl: j['siteUrl'] as String? ?? 'https://yachiyo.hk',
    llmUrl:
        j['llmUrl'] as String? ?? 'http://localhost:11434/v1/chat/completions',
    model: j['model'] as String? ?? '',
    apiKey: apiKey,
    ttsUrl: j['ttsUrl'] as String? ?? '',
    ttsKey: ttsKey,
    ttsModel: j['ttsModel'] as String? ?? 'tts-1',
    voice: j['voice'] as String? ?? 'alloy',
    ttsFormat: j['ttsFormat'] == 'mp3' ? 'mp3' : 'wav',
    demo: j['demo'] as bool? ?? false,
    speak: j['speak'] as bool? ?? false,
    options: Map<String, dynamic>.from(j['options'] as Map? ?? {}),
    mcpKey: mcpKey,
  );
}

class ChatTurn {
  const ChatTurn({
    required this.id,
    required this.user,
    required this.assistant,
    required this.createdAt,
    this.pending = false,
    this.image,
    this.memoryEnabled = true,
    this.memorySource = 'cloud',
    this.localMemoryKey,
  });
  final String id, user, assistant;
  final DateTime createdAt;
  final bool pending, memoryEnabled;
  final String memorySource;
  final String? localMemoryKey;
  final Map<String, dynamic>? image;
  ChatTurn synced() => ChatTurn(
    id: id,
    user: user,
    assistant: assistant,
    createdAt: createdAt,
    image: image,
    memoryEnabled: memoryEnabled,
    memorySource: memorySource,
    localMemoryKey: localMemoryKey,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'user': user,
    'assistant': assistant,
    'createdAt': createdAt.toIso8601String(),
    'pending': pending,
    'image': image,
    'memoryEnabled': memoryEnabled,
    if (memorySource == 'local') 'memorySource': 'local',
    if (localMemoryKey != null) 'localMemoryKey': localMemoryKey,
  };
  factory ChatTurn.fromJson(Map<String, dynamic> j) => ChatTurn(
    id: j['id'] as String,
    user: j['user'] as String,
    assistant: j['assistant'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    pending: j['pending'] == true,
    image: j['image'] is Map ? Map<String, dynamic>.from(j['image']) : null,
    memoryEnabled: j['memoryEnabled'] != false,
    memorySource: j['memorySource'] == 'local' ? 'local' : 'cloud',
    localMemoryKey: j['localMemoryKey'] as String?,
  );
}

class Account {
  const Account(
    this.id,
    this.username, {
    this.role = 'user',
    this.scope = 'user',
    this.nickname = '',
  });
  final String id, username, role, scope, nickname;
  String get displayName => nickname.trim().isEmpty ? username : nickname;
  bool get isAdministrator => role == 'admin' || role == 'super_admin';
}

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

String userDisplayName(
  Map value, {
  String prefix = '',
  String fallback = '访客',
}) {
  for (final key
      in prefix.isEmpty
          ? ['nickname', 'username']
          : ['${prefix}_nickname', '${prefix}_username', prefix]) {
    final name = '${value[key] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
  }
  return fallback;
}

String? nicknameError(String value) {
  final name = value.trim();
  if (name.isEmpty || name.runes.length > 32) return '昵称应为 1 至 32 个字符';
  if (name.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    return '昵称包含无效字符';
  }
  if (RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')
      .hasMatch(name)) {
    return '昵称不能包含控制字符';
  }
  return null;
}
