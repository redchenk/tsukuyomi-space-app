import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const characterPrompt =
    '你是月读空间里的月见八千代。用温柔、自然的中文陪伴用户，回答简短，尊重用户自主性。'
    '不要宣称自己能执行没有提供的工具，不要编造用户的记忆。';

abstract interface class ChatService {
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  );
  void cancel();
}

class LlmClient implements ChatService {
  LlmClient({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  http.Client? _active;
  int _generation = 0;
  @override
  void cancel() {
    _generation++;
    _active?.close();
    _active = null;
  }

  @override
  Stream<String> reply(
    RoomSettings settings,
    List<ChatTurn> history,
    String message,
  ) async* {
    cancel();
    final generation = _generation;
    if (settings.demo) {
      const text = '我在这里。今天想聊聊什么？\n\n这是离线演示回复，用来体验对话节奏。连接你的模型后，我们就可以正式开始了。';
      for (final rune in text.runes) {
        await Future<void>.delayed(const Duration(milliseconds: 24));
        if (generation != _generation) return;
        yield String.fromCharCode(rune);
      }
      return;
    }
    final uri = endpointUri(settings.llmUrl);
    if (settings.model.trim().isEmpty) throw const ApiFailure('请先在设置中填写模型名称');
    final client = _clientFactory();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
          if (settings.apiKey.isNotEmpty)
            'Authorization': 'Bearer ${settings.apiKey}',
        })
        ..body = jsonEncode({
          'model': settings.model,
          'stream': true,
          'messages': [
            {'role': 'system', 'content': characterPrompt},
            for (final turn in history.skip(
              history.length > 12 ? history.length - 12 : 0,
            )) ...[
              {'role': 'user', 'content': turn.user},
              {'role': 'assistant', 'content': turn.assistant},
            ],
            {'role': 'user', 'content': message},
          ],
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw ApiFailure(
          '模型请求失败（HTTP ${response.statusCode}）',
          status: response.statusCode,
        );
      }
      var total = 0;
      await for (final delta in decodeCompletion(
        response.stream.timeout(const Duration(seconds: 45)),
      )) {
        if (generation != _generation) return;
        total += delta.length;
        if (total > 200000) throw const ApiFailure('回复过长，请缩短请求');
        yield delta;
      }
    } on TimeoutException {
      throw const ApiFailure('模型响应超时，请稍后重试');
    } finally {
      client.close();
      if (identical(_active, client)) _active = null;
    }
  }
}

/// SSE lines can split anywhere, including within UTF-8 characters and CRLF.
/// A socket EOF is not proof of a completed answer.
Stream<String> decodeCompletion(Stream<List<int>> bytes) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  final data = <String>[];
  var size = 0, completed = false;
  List<String> consume() {
    if (data.isEmpty) return [];
    final raw = data.join('\n');
    data.clear();
    size = 0;
    if (raw == '[DONE]') {
      completed = true;
      return [];
    }
    final value = jsonDecode(raw) as Map<String, dynamic>;
    if (value['error'] != null) throw const ApiFailure('模型服务返回错误，请检查设置');
    final choices = value['choices'] as List? ?? [];
    final deltas = <String>[];
    for (final item in choices) {
      if (item['index'] != null && item['index'] != 0) continue;
      final reason = item['finish_reason'];
      if (reason != null && reason != 'stop') {
        throw const ApiFailure('模型回复未完整结束，请重试');
      }
      if (reason == 'stop') completed = true;
      final content = item['delta']?['content'];
      if (content is String) deltas.add(content);
    }
    return deltas;
  }

  await for (final line in lines) {
    if (line.isEmpty) {
      for (final delta in consume()) {
        yield delta;
      }
      if (completed) return;
    } else if (line.startsWith('data:')) {
      final value = line.substring(5).trimLeft();
      size += value.length;
      if (size > 1024 * 1024) throw const ApiFailure('模型事件过大');
      data.add(value);
    }
  }
  for (final delta in consume()) {
    yield delta;
  }
  if (!completed) throw const ApiFailure('连接中断，未完成的回复没有保存');
}
