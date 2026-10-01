import 'dart:convert';

import '../models.dart';

class AgentEvent {
  AgentEvent(this.type, this.text, {this.id = '', this.data = const {}})
    : at = DateTime.now();
  AgentEvent.fromJson(Map<String, dynamic> json)
    : type = json['type'] as String,
      text = json['text'] as String,
      id = json['id'] as String? ?? '',
      data = Map<String, dynamic>.from(json['data'] as Map? ?? {}),
      at = DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now();
  final String type, text, id;
  final Map<String, dynamic> data;
  final DateTime at;
  Map<String, dynamic> toJson() => {
    'type': type,
    'text': text,
    'id': id,
    'data': data,
    'at': at.toIso8601String(),
  };
}

typedef AgentEmit = void Function(AgentEvent event);

class AgentResponseTimeout extends ApiFailure {
  const AgentResponseTimeout() : super('自动模式长时间未收到模型输出');
}

class AgentSession {
  AgentSession({
    required this.id,
    required this.owner,
    required this.workspace,
    List<AgentEvent>? events,
    this.nativeId,
  }) : events = events ?? [];
  final String id, owner, workspace;
  String? nativeId;
  final List<AgentEvent> events;
  Map<String, dynamic> toJson() => {
    'id': id,
    'owner': owner,
    'workspace': workspace,
    'events': events.map((e) => e.toJson()).toList(),
    'nativeId': nativeId,
  };
  factory AgentSession.decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    return AgentSession(
      id: json['id'] as String,
      owner: json['owner'] as String,
      workspace: json['workspace'] as String,
      nativeId: json['nativeId'] as String?,
      events: (json['events'] as List)
          .whereType<Map>()
          .map((e) => AgentEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class AgentApproval {
  AgentApproval(this.tool, this.arguments, this.reason);
  final String tool, reason;
  final Map<String, dynamic> arguments;
}

typedef AgentApprove = Future<bool> Function(AgentApproval approval);

abstract interface class AgentRuntime {
  Future<void> start(AgentSession session);
  Future<void> resume(AgentSession session);
  Future<void> send(
    AgentSession session,
    String message,
    RoomSettings settings,
    AgentEmit emit,
  );
  Future<void> cancel();
  Future<void> dispose();
}

abstract interface class AgentArticleDraft {
  String get draftKey;
  String get revision;
  Map<String, dynamic> get fields;
  void applyAgentDraft(String expectedRevision, Map<String, dynamic> changes);
  Future<bool> saveDraft();
  Future<Map<String, dynamic>?> submit();
}
