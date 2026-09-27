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
    this.demo = true,
    this.speak = false,
  });
  final String siteUrl, llmUrl, model, apiKey, ttsUrl, ttsKey, ttsModel, voice;
  final bool demo, speak;
  Map<String, dynamic> toJson() => {
    'siteUrl': siteUrl,
    'llmUrl': llmUrl,
    'model': model,
    'ttsUrl': ttsUrl,
    'ttsModel': ttsModel,
    'voice': voice,
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
