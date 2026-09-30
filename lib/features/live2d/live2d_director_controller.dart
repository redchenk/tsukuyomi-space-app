import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/llm_client.dart';
import '../../core/models.dart';
import '../../core/room_archive.dart';
import '../../live2d/live2d_semantics.dart';
import '../../live2d/room_animation.dart';
import '../room/room_controller.dart';

String _withoutThoughts(String raw) {
  final clean = raw.replaceAll(
    RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
    '',
  );
  final unfinished = clean.toLowerCase().indexOf('<think>');
  return unfinished < 0 ? clean : clean.substring(0, unfinished);
}

String _cleanReply(String raw) => _withoutThoughts(raw)
    .replaceAll(
      RegExp(
        r'^\s*(?:动作|表情|姿态|语气|神态|Action|Expression|BEAT|EMOTION_BEAT|ACTION_BEAT|CONTROL|JSON|LIVE2D_CONTROL)\s*[:：][^\n]*$',
        multiLine: true,
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

class Live2DSpeechLine {
  const Live2DSpeechLine(this.text, this.intent);
  final String text;
  final Map<String, dynamic> intent;
}

/// Parses the original BEAT / VOICE / CONTROL stream incrementally; machine
/// controls and reasoning never become captions or synthesized speech.
class Live2DStreamDecoder {
  String _seen = '', _buffer = '';
  int _beatCount = 0, emitted = 0;
  final List<Map<String, dynamic>> _beats = [];
  List<Live2DSpeechLine> push(String raw, {bool flush = false}) {
    final clean = _withoutThoughts(raw);
    final beforeControl = clean
        .split(
          RegExp(
            r'\n\s*(?:CONTROL|JSON|LIVE2D_CONTROL)\s*[:：]',
            caseSensitive: false,
          ),
        )
        .first;
    final beatMatches = RegExp(
      r'^(?:BEAT|EMOTION_BEAT|ACTION_BEAT)\s*[:：]\s*(\{[^\n]*\})\s*$',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(beforeControl).toList();
    for (final match in beatMatches.skip(_beatCount)) {
      try {
        _beats.add(jsonMap(jsonDecode(match[1]!)));
      } catch (_) {}
    }
    _beatCount = beatMatches.length;
    var visible = RegExp(
      r'^\s*(?:VOICE|SAY|SPEECH|LINE)\s*[:：]\s*(.*)',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(beforeControl).map((m) => m[1]!).join('\n').trim();
    if (visible.isEmpty) visible = _partialReply(clean);
    if (visible.startsWith(_seen)) {
      _buffer += visible.substring(_seen.length);
      _seen = visible;
    }
    final result = <Live2DSpeechLine>[];
    while (_buffer.isNotEmpty) {
      final first = emitted == 0;
      var units = 0, cut = -1;
      for (var i = 0; i < _buffer.length; i++) {
        final ch = _buffer[i];
        if (!RegExp(r'[\s\p{P}]', unicode: true).hasMatch(ch)) units++;
        if ((RegExp(r'[。！？.!?…，,;；\n]').hasMatch(ch) &&
                (flush || units >= (first ? 8 : 20))) ||
            (!flush && units >= (first ? 16 : 42))) {
          cut = i + 1;
          break;
        }
      }
      if (cut < 0 && !flush) break;
      if (cut < 0) cut = _buffer.length;
      final text = _buffer.substring(0, cut).trim();
      _buffer = _buffer.substring(cut);
      if (text.isEmpty) continue;
      final beat = _beats.isEmpty ? null : _beats.removeAt(0);
      result.add(
        Live2DSpeechLine(
          text,
          beat == null
              ? Live2DSemantics.infer(text)
              : Live2DSemantics.step(beat) ?? Live2DSemantics.infer(text),
        ),
      );
      emitted++;
    }
    return result;
  }

  String _partialReply(String source) {
    final marker = RegExp(r'"(?:reply|text|message)"\s*:\s*"')
        .firstMatch(source);
    if (marker == null) return '';
    final chars = StringBuffer();
    for (var i = marker.end; i < source.length; i++) {
      final ch = source[i];
      if (ch == '"') break;
      if (ch != '\\') {
        chars.write(ch);
        continue;
      }
      if (++i >= source.length) break;
      if (source[i] == 'u') {
        if (i + 4 >= source.length) break;
        final code = int.tryParse(source.substring(i + 1, i + 5), radix: 16);
        if (code == null) break;
        chars.writeCharCode(code);
        i += 4;
      } else {
        chars.write(switch (source[i]) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => source[i],
        });
      }
    }
    return chars.toString();
  }

  static Map<String, dynamic> parse(String raw) {
    final clean = _withoutThoughts(raw);
    final control = RegExp(
      r'(?:^|\n)\s*(?:CONTROL|JSON|LIVE2D_CONTROL)\s*[:：]',
      caseSensitive: false,
    ).firstMatch(clean);
    final tail = control == null ? clean : clean.substring(control.end);
    final start = tail.indexOf('{'), end = tail.lastIndexOf('}');
    try {
      if (start >= 0 && end > start) {
        final map = jsonMap(jsonDecode(tail.substring(start, end + 1)));
        final reply = _cleanReply(
          '${map['reply'] ?? map['text'] ?? map['message'] ?? ''}',
        );
        return {
          'reply': reply,
          'intent': Live2DSemantics.sequence(map),
          'raw': map,
        };
      }
    } catch (_) {}
    final speech = RegExp(
      r'^\s*(?:VOICE|SAY|SPEECH|LINE)\s*[:：]\s*(.*)',
      multiLine: true,
      caseSensitive: false,
    ).allMatches(clean).map((m) => m[1]!).join('\n').trim();
    final reply = speech.isNotEmpty ? speech : _cleanReply(clean);
    return {
      'reply': reply,
      'intent': [Live2DSemantics.infer(reply)],
      'raw': raw,
    };
  }
}

class Live2DDirectorController extends ChangeNotifier {
  Live2DDirectorController(
    this.room, {
    ChatService? chat,
    RoomAnimation? animation,
  }) : chat = chat ?? LlmClient(),
       animation = animation ?? RoomAnimation() {
    _scope = scope;
    room.addListener(_accountChanged);
    _restoring = _restore();
  }
  final RoomController room;
  final ChatService chat;
  final RoomAnimation animation;
  String topic = '深夜 AI VTuber 测试直播',
      caption = '',
      raw = '',
      error = '',
      speechError = '',
      status = 'idle';
  bool loading = false, running = false, autoVoice = true, _disposed = false;
  int turn = 0, _generation = 0, _historyTicket = 0;
  String _scope = '';
  final audienceQueue = <String>[],
      history = <ChatTurn>[],
      showLog = <Map<String, dynamic>>[];
  Map<String, dynamic> intent = {};
  Timer? _liveTimer;
  Future<void> _speechTail = Future<void>.value(),
      _historyWrites = Future<void>.value();
  Future<void> _restoring = Future<void>.value();
  String get scope =>
      '${endpointUri(room.settings.siteUrl).origin}:${room.sessionExpired ? 'guest' : room.account?.id ?? 'guest'}';
  String get historyKey => 'live2d-director-history:$scope';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _log(String role, String text) {
    if (text.trim().isEmpty) return;
    showLog.add({
      'role': role,
      'text': text.trim(),
      'createdAt': DateTime.now().toIso8601String(),
    });
    if (showLog.length > 10) showLog.removeAt(0);
    _changed();
  }

  void _accountChanged() {
    if (_scope == scope) return;
    _scope = scope;
    stop();
    _historyTicket++;
    history.clear();
    showLog.clear();
    audienceQueue.clear();
    caption = '';
    raw = '';
    intent = {};
    _restoring = _restore();
    _changed();
  }

  Future<void> _restore() async {
    final ticket = ++_historyTicket, owner = scope;
    try {
      final value = await room.storage.draft(historyKey);
      if (_disposed ||
          ticket != _historyTicket ||
          owner != scope ||
          value.isEmpty) {
        return;
      }
      history.addAll(
        jsonRows(jsonDecode(value)).map(ChatTurn.fromJson).take(4),
      );
    } catch (_) {
      /* Corrupt local history does not block controls. */
    }
  }

  void _save() {
    _historyTicket++;
    final key = historyKey,
        value = jsonEncode(history.map((t) => t.toJson()).toList());
    _historyWrites = _historyWrites
        .then((_) => room.storage.saveDraft(key, value))
        .catchError((_) {});
  }

  void sendAudience(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    if (audienceQueue.length >= 30) audienceQueue.removeAt(0);
    audienceQueue.add(text);
    _log('audience', text);
    if (running && !loading) _schedule(const Duration(milliseconds: 450));
  }

  String directorPrompt(List<String> lines) => [
    'LIVE_DIRECTOR_TICK',
    'Stream topic: ${topic.trim().isEmpty ? 'free talk' : topic}',
    'Recent audience messages:',
    lines.isEmpty
        ? 'No new audience messages. Continue the show with a short autonomous streamer thought.'
        : [for (var i = 0; i < lines.length; i++) '${i + 1}. ${lines[i]}']
              .join('\n'),
    'Act like an autonomous AI VTuber streamer. Reply with 1-2 short spoken sentences.',
    'Do not wait passively for instructions. React, tease gently, ask a tiny hook, or continue the topic.',
    'Choose a visible bodyPose every turn unless the moment is intentionally calm.',
    'Prefer nod, lean_in, sway, bounce, shake_head, or emphasis. Use expression and expressionMix too.',
  ].join('\n');
  Future<void> perform(
    String message, {
    bool streaming = true,
    bool speak = false,
  }) async {
    final text = message.trim();
    if (text.isEmpty || loading) return;
    if (room.busy || room.generating) {
      error = '请等待当前房间操作完成';
      _changed();
      return;
    }
    if (room.settings.demo && chat is LlmClient) {
      error = '请在房间设置配置模型并关闭离线演示后运行导演';
      _changed();
      return;
    }
    final ticket = ++_generation, owner = scope;
    final decoder = Live2DStreamDecoder();
    loading = true;
    error = '';
    speechError = '';
    raw = '';
    status = 'thinking';
    _changed();
    if (chat case final LlmClient llm) {
      llm.systemOverride = [
        room.settings.option('systemPrompt'),
        streaming
            ? Live2DSemantics.streamingPrompt
            : Live2DSemantics.controlPrompt,
      ].where((s) => s.isNotEmpty).join('\n\n');
      llm.siteCookie = room.sessionExpired ? null : room.site.cookie;
    }
    try {
      await _restoring;
      if (_disposed || ticket != _generation || owner != scope) return;
      await for (final delta in chat.reply(
        room.settings,
        List.of(history),
        text,
      )) {
        if (_disposed || ticket != _generation || owner != scope) return;
        raw += delta;
        if (streaming) {
          for (final line in decoder.push(raw)) {
            _line(line, speak, ticket);
          }
        }
        _changed();
      }
      if (_disposed || ticket != _generation || owner != scope) return;
      final result = Live2DStreamDecoder.parse(raw),
          reply = '${result['reply']}';
      final sequence = jsonRows(result['intent']);
      intent = sequence.firstOrNull ?? {};
      if (streaming) {
        for (final line in decoder.push(raw, flush: true)) {
          _line(line, speak, ticket);
        }
      }
      if (decoder.emitted == 0) {
        if (speak && reply.isNotEmpty) {
          _line(
            Live2DSpeechLine(
              reply,
              intent.isEmpty ? Live2DSemantics.infer(reply) : intent,
            ),
            true,
            ticket,
          );
        } else {
          caption = reply;
          if (sequence.isNotEmpty) animation.custom({'sequence': sequence});
          _log('yachiyo', reply);
        }
      }
      history.add(
        ChatTurn(
          id: newTurnId(),
          user: text,
          assistant: reply,
          createdAt: DateTime.now(),
        ),
      );
      if (history.length > 4) history.removeAt(0);
      _save();
      if (speak) await _speechTail;
      if (_disposed || ticket != _generation || owner != scope) return;
      loading = false;
      status = 'idle';
      _changed();
    } catch (e) {
      if (!_disposed && ticket == _generation) {
        loading = false;
        status = 'idle';
        error = '$e';
        _changed();
      }
    }
  }

  void _line(Live2DSpeechLine line, bool speak, int ticket) {
    if (speak) {
      _speechTail = _speechTail.then((_) => _speak(line, ticket)).catchError((
        e,
      ) {
        if (!_disposed && ticket == _generation) {
          speechError = '$e';
          _changed();
        }
      });
    } else {
      caption = line.text;
      intent = line.intent;
      animation.custom(line.intent);
      _log('yachiyo', line.text);
    }
  }

  Future<void> _speak(Live2DSpeechLine line, int ticket) async {
    if (_disposed || ticket != _generation) return;
    final voice = room.voice, ended = Completer<void>();
    var started = false;
    void start() {
      if (started || _disposed || ticket != _generation) return;
      started = true;
      caption = line.text;
      intent = line.intent;
      status = 'speaking';
      animation.custom(line.intent);
      _log('yachiyo', line.text);
    }

    void listener() {
      if (voice.playing) {
        start();
      } else if (started && !ended.isCompleted) {
        ended.complete();
      }
    }

    voice.addListener(listener);
    try {
      final settings = room.settings.copyWith(
        options: {
          ...room.settings.options,
          'speechStyle': line.intent['speechStyle'] ?? {},
          'speechEmotion':
              line.intent['emotion'] ?? line.intent['expression'] ?? 'neutral',
        },
      );
      await voice.speak(settings, line.text);
      if (_disposed || ticket != _generation) return;
      if (!started) start();
      if (voice.playing) {
        await ended.future.timeout(const Duration(seconds: 120));
      }
    } finally {
      voice.removeListener(listener);
    }
  }

  Future<void> speakCaption() async {
    if (caption.isEmpty || loading) return;
    speechError = '';
    try {
      await _speak(
        Live2DSpeechLine(
          caption,
          intent.isEmpty ? Live2DSemantics.infer(caption) : intent,
        ),
        _generation,
      );
    } catch (e) {
      speechError = '$e';
      _changed();
    }
  }

  void start() {
    if (running || loading) return;
    running = true;
    _log('system', '直播导演已启动');
    _runLive();
  }

  void _schedule(Duration delay) {
    _liveTimer?.cancel();
    if (running && !_disposed) _liveTimer = Timer(delay, _runLive);
  }

  Future<void> _runLive() async {
    if (!running || loading || _disposed) return;
    final lines = audienceQueue.take(3).toList();
    audienceQueue.removeRange(0, lines.length);
    final initialGeneration = _generation;
    await perform(
      directorPrompt(lines),
      streaming: autoVoice,
      speak: autoVoice,
    );
    if (!running || _disposed || _generation > initialGeneration + 1) return;
    if (error.isEmpty) turn++;
    _changed();
    _schedule(Duration(milliseconds: audienceQueue.isEmpty ? 9000 : 900));
  }

  void stop() {
    final wasRunning = running;
    running = false;
    loading = false;
    status = 'idle';
    _generation++;
    _liveTimer?.cancel();
    _liveTimer = null;
    chat.cancel();
    unawaited(room.voice.stop());
    animation.clear();
    if (wasRunning) _log('system', '直播导演已停止');
    _changed();
  }

  void clearHistory() {
    stop();
    history.clear();
    showLog.clear();
    audienceQueue.clear();
    caption = '';
    raw = '';
    intent = {};
    error = '';
    speechError = '';
    turn = 0;
    _save();
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _liveTimer?.cancel();
    chat.cancel();
    room.removeListener(_accountChanged);
    unawaited(room.voice.stop());
    animation.dispose();
    super.dispose();
  }
}
