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
    this.demo = true,
    this.speak = false,
  });
  final String siteUrl, llmUrl, model, apiKey, ttsUrl, ttsKey, ttsModel, voice;
  final String ttsFormat;
  final bool demo, speak;
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
  };
  factory RoomSettings.fromJson(
    Map<String, dynamic> j, {
    String apiKey = '',
    String ttsKey = '',
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
    demo: j['demo'] as bool? ?? true,
    speak: j['speak'] as bool? ?? false,
  );
}

class ChatTurn {
  const ChatTurn({
    required this.id,
    required this.user,
    required this.assistant,
    required this.createdAt,
    this.pending = false,
  });
  final String id, user, assistant;
  final DateTime createdAt;
  final bool pending;
  ChatTurn synced() =>
      ChatTurn(id: id, user: user, assistant: assistant, createdAt: createdAt);
  Map<String, dynamic> toJson() => {
    'id': id,
    'user': user,
    'assistant': assistant,
    'createdAt': createdAt.toIso8601String(),
    'pending': pending,
  };
  factory ChatTurn.fromJson(Map<String, dynamic> j) => ChatTurn(
    id: j['id'] as String,
    user: j['user'] as String,
    assistant: j['assistant'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    pending: j['pending'] == true,
  );
}

class Account {
  const Account(this.id, this.username);
  final String id, username;
}

class ApiFailure implements Exception {
  const ApiFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}
