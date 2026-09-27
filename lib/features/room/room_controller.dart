import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/llm_client.dart';
import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/storage.dart';
import '../../core/voice_service.dart';

class RoomController extends ChangeNotifier {
  RoomController({
    required this.storage,
    required this.chat,
    required this.site,
    required this.voice,
  }) {
    voice.addListener(_changed);
  }
  final RoomStorage storage;
  final ChatService chat;
  final SiteService site;
  final VoiceService voice;
  RoomSettings settings = const RoomSettings();
  Account? account;
  List<ChatTurn> turns = [];
  String draft = '',
      partial = '',
      sendingText = '',
      error = '',
      syncStatus = '仅保存在此设备';
  bool loading = true, generating = false, busy = false, sessionExpired = false;
  int _generation = 0;
  bool _disposed = false, _syncing = false;
  DateTime? _conversationStart;
  List<ChatTurn> get visibleTurns => _conversationStart == null
      ? turns
      : turns.where((t) => !t.createdAt.isBefore(_conversationStart!)).toList();
  String get scope => settings.demo
      ? 'demo'
      : '${endpointUri(settings.siteUrl).origin}:${account?.id ?? 'guest'}';
  String get _sessionKey => 'session.${endpointUri(settings.siteUrl).origin}';
  bool get canSend => !generating && !busy && !loading && !_syncing;
  int get pendingCount => turns.where((t) => t.pending).length;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      settings = await storage.settings();
      if (!settings.demo && !kIsWeb) {
        site.cookie = await storage.readSecret(_sessionKey);
        if (site.cookie != null) {
          try {
            account = await site.me(settings.siteUrl);
          } on ApiFailure catch (e) {
            if (e.status == 401 || e.status == 403) {
              site.cookie = null;
              await storage.writeSecret(_sessionKey, null);
            }
            error = e.message;
          }
        }
      }
      await _loadScope();
      if (account != null) await sync();
    } catch (_) {
      error = '无法读取本地设置或安全存储，请检查系统密钥环';
    } finally {
      loading = false;
      _changed();
    }
  }

  Future<void> _loadScope() async {
    _conversationStart = null;
    turns = await storage.history(scope);
    draft = await storage.draft(scope);
    partial = '';
    sendingText = '';
    syncStatus = account == null || settings.demo ? '仅保存在此设备' : '等待同步';
  }

  /// Start a fresh model context while retaining every saved turn in history.
  Future<void> startConversation() async {
    if (!canSend) return;
    busy = true;
    _changed();
    try {
      await storage.saveDraft(scope, '');
      await voice.stop();
      _conversationStart = DateTime.now();
      draft = '';
      error = '';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> configure(RoomSettings value) async {
    if (generating || busy || _syncing) throw const ApiFailure('请等待当前操作完成');
    endpointUri(value.siteUrl);
    if (!value.demo) endpointUri(value.llmUrl);
    if (value.speak) endpointUri(value.ttsUrl);
    busy = true;
    _changed();
    try {
      await voice.stop();
      await storage.saveSettings(value);
      final changedAccount =
          endpointUri(value.siteUrl).origin !=
          endpointUri(settings.siteUrl).origin;
      settings = value;
      if (changedAccount) {
        account = null;
        site.cookie = null;
        sessionExpired = false;
      }
      await _loadScope();
      error = '';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> login(String username, String password) async {
    if (generating || busy || _syncing) {
      throw const ApiFailure('请等待当前操作完成');
    }
    if (kIsWeb) throw const ApiFailure('请使用原生应用登录；Web 仅用于界面预览');
    busy = true;
    error = '';
    _changed();
    try {
      await voice.stop();
      final user = await site.login(settings.siteUrl, username, password);
      await storage.writeSecret(_sessionKey, site.cookie);
      account = user;
      sessionExpired = false;
      await _loadScope();
    } catch (_) {
      site.cookie = null;
      rethrow;
    } finally {
      busy = false;
      _changed();
    }
    if (!settings.demo) await sync();
  }

  Future<void> logout() async {
    if (busy || _syncing) {
      throw const ApiFailure('请等待同步完成');
    }
    stop();
    busy = true;
    _changed();
    try {
      try {
        await site.logout(settings.siteUrl);
      } catch (_) {
        /* Always clear local credentials. */
      }
      site.cookie = null;
      await storage.writeSecret(_sessionKey, null);
      account = null;
      sessionExpired = false;
      await _loadScope();
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> send(String text) async {
    text = text.trim();
    if (text.isEmpty || generating || busy || loading || _syncing) return;
    if (text.length > 12000) {
      error = '消息过长，请控制在 12000 字以内';
      _changed();
      return;
    }
    final generation = ++_generation;
    final targetScope = scope;
    generating = true;
    sendingText = text;
    partial = '';
    draft = text;
    error = '';
    _changed();
    try {
      await storage.saveDraft(targetScope, text);
      await voice.stop();
      if (generation != _generation || _disposed) return;
      await for (final delta in chat.reply(
        settings,
        List.of(visibleTurns),
        text,
      )) {
        if (generation != _generation || _disposed) return;
        partial += delta;
        _changed();
      }
      if (generation != _generation || _disposed) return;
      if (partial.trim().isEmpty) throw const ApiFailure('模型没有返回可显示的回复');
      final turn = ChatTurn(
        id: newTurnId(),
        user: text,
        assistant: partial,
        createdAt: DateTime.now(),
        pending: account != null && !settings.demo,
      );
      final updated = [...turns, turn];
      // Persist a completed turn before any network upload; its ID is reused on retry.
      await storage.saveHistory(targetScope, updated);
      if (generation != _generation || _disposed) return;
      turns = updated;
      await storage.saveDraft(targetScope, '');
      draft = '';
      partial = '';
      sendingText = '';
      generating = false;
      _changed();
      if (settings.speak && !settings.demo) unawaited(_speak(turn.assistant));
      if (account != null && !settings.demo) await sync();
    } catch (e) {
      if (generation == _generation && !_disposed) {
        error = e is ApiFailure ? e.message : '连接失败，请检查服务设置后重试';
      }
    } finally {
      if (generation == _generation) {
        generating = false;
        partial = '';
        sendingText = '';
        _changed();
      }
    }
  }

  Future<void> _speak(String text) async {
    try {
      await voice.speak(settings, text);
    } catch (_) {
      if (!_disposed) {
        error = '语音播放失败，对话已保存；请检查 TTS 设置';
        _changed();
      }
    }
  }

  Future<void> replay(String text) async {
    if (!settings.speak || settings.demo) {
      error = '请先连接 TTS 并开启语音';
      _changed();
      return;
    }
    await _speak(text);
  }

  void stop() {
    _generation++;
    chat.cancel();
    unawaited(voice.stop());
    generating = false;
    partial = '';
    sendingText = '';
    _changed();
  }

  Future<void> sync() async {
    if (account == null ||
        settings.demo ||
        sessionExpired ||
        _syncing ||
        generating) {
      return;
    }
    _syncing = true;
    syncStatus = '正在同步';
    _changed();
    final targetScope = scope;
    try {
      for (final turn in List<ChatTurn>.of(turns.where((t) => t.pending))) {
        await site.saveTurn(settings.siteUrl, turn);
        turns = turns.map((t) => t.id == turn.id ? t.synced() : t).toList();
        await storage.saveHistory(targetScope, turns);
      }
      final remote = await site.history(settings.siteUrl);
      // The server owns the canonical list, including edits/deletions from other devices.
      turns = remote;
      await storage.saveHistory(targetScope, turns);
      syncStatus = '已与月读空间同步';
    } catch (e) {
      syncStatus = pendingCount > 0 ? '$pendingCount 轮等待重试' : '离线，保留本地记录';
      if (e is ApiFailure && (e.status == 401 || e.status == 403)) {
        sessionExpired = true;
        site.cookie = null;
        await storage.writeSecret(_sessionKey, null);
        syncStatus = '登录已过期，请重新登录';
      }
    } finally {
      _syncing = false;
      _changed();
    }
  }

  void pause() {
    stop();
  }

  void resume() {
    unawaited(sync());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    chat.cancel();
    site.dispose();
    voice.removeListener(_changed);
    voice.dispose();
    super.dispose();
  }
}
