import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/llm_client.dart';
import '../../core/models.dart';
import '../../core/site_client.dart';
import '../../core/storage.dart';
import '../../core/voice_service.dart';
import '../../core/room_archive.dart';
import 'room_workspace.dart';
import '../../live2d/room_animation.dart';

class RoomController extends ChangeNotifier {
  RoomController({
    required this.storage,
    required this.chat,
    required this.site,
    required this.voice,
    this.diaryClientFactory,
  }) {
    workspace = RoomWorkspace(this);
    workspace.addListener(_changed);
    voice.addListener(_changed);
    if (site is SiteClient) {
      (site as SiteClient).onUnauthorized = expireSession;
      (site as SiteClient).onReaderCookie = (origin, value) {
        unawaited(storage.writeSecret('reader.$origin', value));
      };
    }
  }
  final RoomStorage storage;
  final ChatService chat;
  final SiteService site;
  final VoiceService voice;
  final ChatService Function()? diaryClientFactory;
  late final RoomWorkspace workspace;
  final animation = RoomAnimation();
  Map<String, dynamic>? attachment;
  List<ChatTurn> recording = [];
  String diaryText = '', diaryStatus = '';
  Map<String, dynamic>? pendingDiary;
  String? _draftTurnId;
  bool _committing = false;
  Future<void> attach(Map<String, dynamic>? value) async {
    if (!canSend) return;
    attachment = value;
    await storage.saveDraft(
      '$scope.image-draft',
      value == null ? '' : jsonEncode(value),
    );
    _changed();
  }

  Future<void> _saveRecording() => storage.saveDraft(
    '$scope.recording',
    jsonEncode({
      'turns': recording.map((v) => v.toJson()).toList(),
      'pendingDiary': pendingDiary,
    }),
  );

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
  Set<String> _previousConversationIds = {};
  List<ChatTurn> get visibleTurns => _conversationStart == null
      ? turns
      : turns
            .where(
              (t) =>
                  !_previousConversationIds.contains(t.id) &&
                  !t.createdAt.isBefore(_conversationStart!),
            )
            .toList();
  String get scope => settings.demo
      ? 'demo'
      : '${endpointUri(settings.siteUrl).origin}:${account?.id ?? 'guest'}';
  String get _sessionKey => 'session.${endpointUri(settings.siteUrl).origin}';
  bool get canSend => !generating && !busy && !loading && !_syncing;
  int get pendingCount => turns.where((t) => t.pending).length;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String get _accountKey => 'account.${endpointUri(settings.siteUrl).origin}';
  Timer? _retry;
  void expireSession() {
    if (account == null || sessionExpired) return;
    sessionExpired = true;
    syncStatus = '登录已过期，请重新登录；本机内容已保留';
    unawaited(storage.writeSecret(_sessionKey, null));
    _changed();
  }

  void _startRetry() {
    _retry?.cancel();
    if (account == null || settings.demo || _disposed) return;
    _retry = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!generating && !busy) {
        unawaited(sync());
        unawaited(workspace.archive.sync());
      }
    });
  }

  Future<void> saveComposerDraft(String value) async {
    if (generating || busy || loading) return;
    draft = value;
    await storage.saveDraft(scope, value);
  }

  Future<void> _rememberAccount() async {
    await storage.saveDraft(
      _accountKey,
      account == null
          ? ''
          : jsonEncode({'id': account!.id, 'username': account!.username}),
    );
  }

  Future<void> initialize() async {
    try {
      settings = await storage.settings();
      if (site is SiteClient) {
        final origin = endpointUri(settings.siteUrl).origin;
        final reader = await storage.readSecret('reader.$origin');
        if (reader != null) (site as SiteClient).readerCookies[origin] = reader;
      }
      if (!kIsWeb) {
        final hint = await storage.draft(_accountKey);
        if (hint.isNotEmpty) {
          try {
            final j = jsonDecode(hint);
            account = Account(j['id'], j['username']);
          } catch (_) {}
        }
        site.cookie = await storage.readSecret(_sessionKey);
        await _loadScope();
        _changed();
        if (site.cookie != null) {
          try {
            account = await site.me(settings.siteUrl);
            await _rememberAccount();
          } on ApiFailure catch (e) {
            if (e.status == 401 || e.status == 403) {
              expireSession();
            }
            error = e.message;
          }
        } else if (account != null) {
          sessionExpired = true;
        }
      }
      await _loadScope();
      if (account != null) await sync();
    } catch (_) {
      error = '无法读取本地设置或安全存储，请检查系统密钥环';
    } finally {
      loading = false;
      _startRetry();
      _changed();
    }
  }

  Future<void> _loadScope() async {
    _conversationStart = null;
    _previousConversationIds = {};
    turns = await storage.history(scope);
    draft = await storage.draft(scope);
    final imageDraft = await storage.draft('$scope.image-draft');
    attachment = imageDraft.isEmpty ? null : jsonMap(jsonDecode(imageDraft));
    _draftTurnId = await storage.draft('$scope.pending-id');
    if (_draftTurnId!.isEmpty) _draftTurnId = null;
    final recorded = await storage.draft('$scope.recording');
    final saved = recorded.isEmpty
        ? <String, dynamic>{}
        : jsonMap(jsonDecode(recorded));
    recording = jsonRows(saved['turns']).map(ChatTurn.fromJson).toList();
    pendingDiary = saved['pendingDiary'] is Map
        ? jsonMap(saved['pendingDiary'])
        : null;
    await workspace.load();
    partial = '';
    sendingText = '';
    syncStatus = account == null || settings.demo ? '仅保存在此设备' : '等待同步';
  }

  /// Start a fresh model context while retaining every saved turn in history.
  Future<void> startConversation({bool clearHistory = false}) async {
    if (!canSend) return;
    busy = true;
    _changed();
    try {
      if (clearHistory && account != null && !settings.demo) {
        if (sessionExpired) throw const ApiFailure('请重新登录后新建云端会话');
        await workspace.request('DELETE', '/api/room/chat');
      }
      if (clearHistory) {
        turns = [];
        recording = [];
        pendingDiary = null;
        attachment = null;
        _draftTurnId = null;
        await storage.saveHistory(scope, []);
        await _saveRecording();
        await storage.saveDraft('$scope.image-draft', '');
        await storage.saveDraft('$scope.pending-id', '');
      }
      await storage.saveDraft(scope, '');
      await voice.stop();
      _conversationStart = DateTime.now();
      // A completed turn can share the same Windows clock tick as this reset.
      // Stable IDs keep that old turn out while allowing new equal-time turns.
      _previousConversationIds = turns.map((turn) => turn.id).toSet();
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
      _startRetry();
      error = '';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> login(
    String username,
    String password, {
    Map<String, dynamic>? credentials,
    String authPath = '/api/auth/login',
  }) async {
    if (generating || busy || _syncing) {
      throw const ApiFailure('请等待当前操作完成');
    }
    if (kIsWeb) throw const ApiFailure('请使用原生应用登录；Web 仅用于界面预览');
    busy = true;
    error = '';
    _changed();
    try {
      await voice.stop();
      final user = credentials != null && site is SiteClient
          ? await (site as SiteClient).authenticate(
              settings.siteUrl,
              credentials,
              path: authPath,
            )
          : await site.login(settings.siteUrl, username, password);
      await storage.writeSecret(_sessionKey, site.cookie);
      account = user;
      await _rememberAccount();
      sessionExpired = false;
      await _loadScope();
    } catch (_) {
      site.cookie = null;
      rethrow;
    } finally {
      busy = false;
      _changed();
    }
    _startRetry();
    if (!settings.demo) await sync();
  }

  Future<void> logout() async {
    if (busy || _syncing || _committing) {
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
      await _rememberAccount();
      sessionExpired = false;
      await _loadScope();
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> send(
    String text, {
    bool opener = false,
    ChatTurn? replacement,
  }) async {
    text = text.trim();
    if ((text.isEmpty && attachment == null && !opener) || !canSend) return;
    if (replacement != null &&
        (turns.isEmpty ||
            turns.last.id != replacement.id ||
            replacement.image != null)) {
      error = '只能修改或重新生成最后一轮无图片的对话';
      _changed();
      return;
    }
    if (replacement != null && replacement.pending) {
      error = '请先同步这轮对话再修改';
      _changed();
      return;
    }
    if (opener && replacement == null && visibleTurns.isNotEmpty) return;
    final requestText = opener
        ? '现在由你先开口。结合当前时间，主动说一句自然、简短、符合你身份的话来开启对话。不要复述这条指令。'
        : text.isEmpty
        ? '请看这张图片。'
        : text;
    final image = replacement == null ? attachment : null;
    final turnId = replacement?.id ?? _draftTurnId ?? newTurnId();
    if (replacement == null) _draftTurnId = turnId;
    if (text.length > 12000) {
      error = '消息过长，请控制在 12000 字以内';
      _changed();
      return;
    }
    final generation = ++_generation;
    final targetScope = scope;
    generating = true;
    sendingText = opener ? '' : requestText;
    partial = '';
    draft = text;
    error = '';
    _changed();
    try {
      await storage.saveDraft(targetScope, text);
      if (replacement == null) {
        await storage.saveDraft('$targetScope.pending-id', turnId);
      }
      await voice.stop();
      if (generation != _generation || _disposed) return;
      if (chat is LlmClient) {
        final llm = chat as LlmClient;
        llm.memoryContext = '';
        llm.systemOverride = '';
        llm.referenceContext = '';
        llm.siteCookie = site.cookie;
        llm.image = settings.option('visionMode', 'auto') == 'mcp'
            ? null
            : image;
        llm.referenceContext = await workspace.context(
          requestText,
          image: image,
        );
        if (settings.flag('memoryEnabled', true) &&
            !settings.demo &&
            account != null &&
            !sessionExpired &&
            site is SiteDataService) {
          try {
            final result = await (site as SiteDataService)
                .request(
                  settings.siteUrl,
                  'GET',
                  '/api/room/memory?purpose=chat&limit=6&q=${Uri.encodeQueryComponent(text)}',
                )
                .timeout(const Duration(seconds: 2));
            if (generation != _generation || _disposed) return;
            final memories = (result['data'] as List? ?? [])
                .map(
                  (m) =>
                      '${m['context'] ?? m['content'] ?? m['summary'] ?? ''}',
                )
                .where((m) => m.isNotEmpty);
            (chat as LlmClient).memoryContext = memories
                .join('\n')
                .substring(0, memories.join('\n').length.clamp(0, 8000));
          } catch (_) {
            syncStatus = '记忆暂不可用，本轮仍可对话';
          }
        }
      }
      if (generation != _generation || _disposed) return;
      await for (final delta in chat.reply(
        settings,
        List.of(visibleTurns.where((v) => v.id != replacement?.id)),
        requestText,
      )) {
        if (generation != _generation || _disposed) return;
        partial += delta;
        _changed();
      }
      if (generation != _generation || _disposed) return;
      if (partial.trim().isEmpty) throw const ApiFailure('模型没有返回可显示的回复');
      final cleaned = cleanRoomReply(partial);
      if (cleaned.isEmpty) throw const ApiFailure('模型没有返回可显示的回复');
      Map<String, dynamic>? savedImage = image;
      _committing = true;
      if (replacement != null && account != null && !settings.demo) {
        if (sessionExpired) throw const ApiFailure('请重新登录后修改云端对话');
        await workspace.request(
          'PUT',
          '/api/room/chat/turn/${Uri.encodeComponent(replacement.id)}',
          {
            'expectedUserMessage': replacement.user,
            'expectedAssistantMessage': replacement.assistant,
            'userMessage': opener ? '' : requestText,
            'assistantMessage': cleaned,
            'memoryEnabled': settings.flag('memoryEnabled', true),
          },
        );
      }
      final turn = ChatTurn(
        id: turnId,
        user: opener ? '' : requestText,
        assistant: cleaned,
        image: savedImage,
        memoryEnabled: settings.flag('memoryEnabled', true),
        createdAt: replacement?.createdAt ?? DateTime.now(),
        pending: replacement == null && account != null && !settings.demo,
      );
      final updated = [...turns.where((v) => v.id != turnId), turn];
      // Persist a completed turn before any network upload; its ID is reused on retry.
      await storage.saveHistory(targetScope, updated);
      if (generation != _generation || _disposed) return;
      turns = updated;
      try {
        await workspace.captureGuestTurn(turn, replace: replacement != null);
      } catch (_) {
        syncStatus = '本轮记忆保存失败，对话已保存';
      }
      animation.react(cleaned);
      recording = [...recording.where((v) => v.id != turnId), turn];
      pendingDiary = null;
      await _saveRecording();
      attachment = null;
      _draftTurnId = null;
      await storage.saveDraft('$targetScope.pending-id', '');
      await storage.saveDraft('$targetScope.image-draft', '');
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
      _committing = false;
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
      if (voice is AudioVoice) (voice as AudioVoice).siteCookie = site.cookie;
      await voice.speak(settings, speechRoomText(text));
    } catch (e) {
      if (!_disposed) {
        error = e is ApiFailure ? e.message : '语音播放失败，对话已保存；请检查 TTS 设置';
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
    if (_committing) return;
    _generation++;
    workspace.tools.cancel();
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
      for (var turn in List<ChatTurn>.of(turns.where((t) => t.pending))) {
        if (turn.image?['dataUrl'] != null && turn.image?['id'] == null) {
          final image = jsonMap(
            (await workspace.request('POST', '/api/room/chat/images', {
              'turnId': turn.id,
              'name': turn.image!['name'],
              'dataUrl': turn.image!['dataUrl'],
            }))['data'],
          );
          turn = ChatTurn.fromJson({...turn.toJson(), 'image': image});
          turns = turns.map((t) => t.id == turn.id ? turn : t).toList();
          await storage.saveHistory(targetScope, turns);
        }
        await site.saveTurn(settings.siteUrl, turn);
        if (targetScope != scope || _disposed) return;
        turns = turns.map((t) => t.id == turn.id ? t.synced() : t).toList();
        await storage.saveHistory(targetScope, turns);
      }
      final remote = await site.history(settings.siteUrl);
      // The server owns the canonical list, including edits/deletions from other devices.
      if (targetScope != scope || _disposed) return;
      turns = remote;
      await storage.saveHistory(targetScope, turns);
      syncStatus = '已与月读空间同步';
    } catch (e) {
      syncStatus = pendingCount > 0 ? '$pendingCount 轮等待重试' : '离线，保留本地记录';
      if (e is ApiFailure) syncStatus += '：${e.message}';
      if (e is ApiFailure && (e.status == 401 || e.status == 403)) {
        expireSession();
        syncStatus = '登录已过期，请重新登录';
      }
    } finally {
      _syncing = false;
      _changed();
    }
  }

  ChatService? _diaryClient;
  bool _diaryCancelled = false;
  void cancelDiary() {
    _diaryCancelled = true;
    _diaryClient?.cancel();
  }

  Future<Map<String, dynamic>?> finishDiary({bool withoutDiary = false}) async {
    if (!canSend) return null;
    if (recording.isEmpty && !withoutDiary) {
      throw const ApiFailure('本次还没有可记录的对话');
    }
    busy = true;
    _diaryCancelled = false;
    diaryStatus = withoutDiary ? '正在结束会话' : '正在生成日记';
    diaryText = '';
    _changed();
    final target = scope;
    try {
      if (!withoutDiary) {
        await workspace.archive.sync();
        final persona = workspace.archive.personaData;
        if (pendingDiary == null) {
          final service = diaryClientFactory?.call() ?? LlmClient();
          _diaryClient = service;
          if (service is LlmClient) {
            service.siteCookie = site.cookie;
            service.systemOverride =
                '你是「${persona['name']}」，请以第一人称把刚结束的对话写成私人日记。角色设定：${persona['description']}。性格：${persona['personality']}。相处背景：${persona['scenario']}。补充设定：${persona['creator_notes']}。只输出日记正文，不要 JSON、标题或额外说明。仅依据对话，不编造重要事件。400–900 字，自然分段。';
          }
          final transcript = recording
              .map((t) => '对方：${t.user}\n我：${t.assistant}')
              .join('\n');
          final prompt =
              '现在是 ${DateTime.now()}。以下是刚刚结束的对话记录：\n<对话开始>\n$transcript\n<对话结束>\n请直接输出日记正文。';
          await for (final delta
              in service
                  .reply(settings, [], prompt)
                  .timeout(const Duration(seconds: 180))) {
            if (target != scope || _disposed) return null;
            if (_diaryCancelled) throw const ApiFailure('日记生成已停止，对话已保留');
            diaryText += delta;
            _changed();
          }
          if (_diaryCancelled) throw const ApiFailure('日记生成已停止，对话已保留');
          final content = cleanRoomReply(diaryText);
          if (content.length < 20) {
            throw const ApiFailure('日记内容过短，请重试；对话记录仍然保留');
          }
          final now = DateTime.now();
          pendingDiary = {
            'diaryId': newTurnId(),
            'content':
                '【日记】\n$content\n\n${now.year}年${now.month}月${now.day}日${now.hour}点${now.minute}分',
            'timestamp': now.millisecondsSinceEpoch,
            'date': '${now.year}/${now.month}/${now.day}',
            'time':
                '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
            'characterName': persona['name'],
            'conversationLength': recording.length * 2,
            'mode': settings.model,
          };
          await workspace.archive.append(pendingDiary!);
          await _saveRecording();
        }
        await workspace.archive.sync();
        if (!workspace.archive.entries.any(
          (entry) => entry['diaryId'] == pendingDiary?['diaryId'],
        )) {
          throw const ApiFailure('这篇日记已在其他设备删除，会话仍然保留；请确认后重试或跳过日记');
        }
        if (account != null &&
            !settings.demo &&
            (!workspace.online || workspace.archive.status != '已与网站同步')) {
          throw const ApiFailure('日记已保存在本机，云端同步尚未完成；重试不会重复生成');
        }
      }
      if (_diaryCancelled) throw const ApiFailure('日记已保留，会话未结束');
      if (account != null && !settings.demo) {
        if (sessionExpired) throw const ApiFailure('请重新登录后结束云端会话');
        await workspace.request('DELETE', '/api/room/chat');
      }
      final result = pendingDiary;
      turns = [];
      recording = [];
      pendingDiary = null;
      draft = '';
      attachment = null;
      _draftTurnId = null;
      await storage.saveHistory(scope, []);
      await _saveRecording();
      await storage.saveDraft(scope, '');
      await storage.saveDraft('$scope.image-draft', '');
      await storage.saveDraft('$scope.pending-id', '');
      diaryStatus = withoutDiary ? '会话已结束' : '日记已保存，会话已结束';
      return result;
    } catch (e) {
      diaryStatus = e is ApiFailure ? e.message : '日记生成失败，对话已保留';
      rethrow;
    } finally {
      _diaryClient?.cancel();
      _diaryClient = null;
      busy = false;
      _changed();
    }
  }

  void pause() {
    _retry?.cancel();
    stop();
  }

  void resume() {
    _startRetry();
    unawaited(sync());
    unawaited(workspace.archive.sync());
    unawaited(workspace.refreshWorld());
  }

  @override
  void dispose() {
    _disposed = true;
    _diaryClient?.cancel();
    _retry?.cancel();
    _generation++;
    chat.cancel();
    site.dispose();
    workspace.removeListener(_changed);
    workspace.dispose();
    animation.dispose();
    voice.removeListener(_changed);
    voice.dispose();
    super.dispose();
  }
}

String cleanRoomReply(String raw) {
  var text = raw
      .replaceAll(
        RegExp(r'<think>[\s\S]*?(?:</think>|$)', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<think>[\s\S]*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'<\|ACT:[\s\S]*?(?:\|>|$)'), '')
      .replaceAll(RegExp(r'<\|DELAY:[^>]+>'), '')
      .trim();
  text = text
      .replaceFirst(RegExp(r'^```(?:json|markdown|text)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```$'), '');
  if (text.startsWith('{')) {
    try {
      final value = jsonDecode(text);
      for (final key in ['reply', 'text', 'content', 'diary']) {
        if (value[key] is String) return value[key];
      }
    } catch (_) {}
  }
  return text
      .replaceAll(
        RegExp(
          r'^(?:动作|表情|姿态|语气|神态|reply|emotion|live2d)\s*[:：][^\n]{0,140}$',
          multiLine: true,
        ),
        '',
      )
      .trim();
}

String speechRoomText(String value) =>
    cleanRoomReply(value)
        .replaceAll(RegExp(r'\([^)]*\)|（[^）]*）|\[[^\]]*\]|【[^】]*】'), '')
        .replaceAll(RegExp(r'[*#`_]'), '')
        .trim();
