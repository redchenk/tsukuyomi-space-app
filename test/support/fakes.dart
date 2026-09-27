import 'dart:async';

import 'package:tsukuyomi_space_app/core/llm_client.dart';
import 'package:tsukuyomi_space_app/core/models.dart';
import 'package:tsukuyomi_space_app/core/site_client.dart';
import 'package:tsukuyomi_space_app/core/storage.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';

class MemoryStorage implements RoomStorage {
  RoomSettings value = const RoomSettings();
  final secrets = <String, String>{};
  final histories = <String, List<ChatTurn>>{};
  final drafts = <String, String>{};
  bool failHistory = false;
  @override
  Future<RoomSettings> settings() async => value;
  @override
  Future<void> saveSettings(RoomSettings v) async {
    value = v;
  }

  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String? v) async {
    if (v == null) {
      secrets.remove(key);
    } else {
      secrets[key] = v;
    }
  }

  @override
  Future<List<ChatTurn>> history(String scope) async =>
      List.of(histories[scope] ?? []);
  @override
  Future<void> saveHistory(String scope, List<ChatTurn> v) async {
    if (failHistory) throw StateError('disk full');
    histories[scope] = List.of(v);
  }

  @override
  Future<String> draft(String scope) async => drafts[scope] ?? '';
  @override
  Future<void> saveDraft(String scope, String v) async {
    drafts[scope] = v;
  }
}

class FakeSite implements SiteService {
  @override
  String? cookie;
  final data = <String, ChatTurn>{};
  final savedIds = <String>[];
  bool offline = false;
  String userId = 'alice';
  @override
  Future<Account> login(String site, String username, String password) async {
    userId = username;
    cookie = 'session';
    return Account(username, username);
  }

  @override
  Future<Account> me(String site) async => Account(userId, userId);
  @override
  Future<void> logout(String site) async {
    cookie = null;
  }

  @override
  Future<List<ChatTurn>> history(String site) async {
    if (offline) throw const ApiFailure('offline');
    return data.values.toList();
  }

  @override
  Future<void> saveTurn(String site, ChatTurn turn) async {
    savedIds.add(turn.id);
    if (offline) throw const ApiFailure('offline');
    data[turn.id] = turn.synced();
  }

  @override
  void dispose() {}
}

class FakeChat implements ChatService {
  List<ChatTurn> lastContext = [];
  StreamController<String>? stream;
  String answer = '这是完整回复。';
  bool controlled = false;
  @override
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  ) {
    lastContext = List.of(history);
    if (controlled) {
      stream = StreamController<String>();
      return stream!.stream;
    }
    return Stream.value(answer);
  }

  @override
  void cancel() {
    unawaited(stream?.close());
  }
}

class SilentVoice extends VoiceService {
  @override
  bool get playing => false;
  @override
  double get mouth => 0;
  @override
  Future<void> speak(RoomSettings settings, String text) async {}
  @override
  Future<void> stop() async {}
}
