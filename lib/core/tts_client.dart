import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class SpeechAudio {
  const SpeechAudio(this.bytes, this.format);
  final Uint8List bytes;
  final String format;
  String get mimeType => format == 'wav' ? 'audio/wav' : 'audio/mpeg';
}

/// Same model/input/voice/response_format contract as the website's ttsTransport.
class TtsClient {
  TtsClient({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  http.Client? _active;

  void cancel() {
    _active?.close();
    _active = null;
  }

  Future<SpeechAudio> synthesize(RoomSettings settings, String text) async {
    cancel();
    final uri = compatibleEndpoint(settings.ttsUrl, speech: true);
    if (settings.ttsModel.isEmpty || settings.voice.isEmpty) {
      throw const ApiFailure('请填写语音模型和音色 ID');
    }
    if (!['wav', 'mp3'].contains(settings.ttsFormat)) {
      throw const ApiFailure('请选择 WAV 或 MP3 音频格式');
    }
    final client = _clientFactory();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Content-Type': 'application/json',
          if (settings.ttsKey.isNotEmpty)
            'Authorization': 'Bearer ${settings.ttsKey}',
        })
        ..body = jsonEncode({
          'model': settings.ttsModel,
          'input': text,
          'voice': settings.voice,
          'response_format': settings.ttsFormat,
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw providerFailure('语音生成', response.statusCode);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (builder.length + chunk.length > 24 * 1024 * 1024) {
          throw const ApiFailure('语音超过 24 MB，请缩短文本');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final wav =
          bytes.length >= 44 &&
          ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WAVE';
      final mp3 =
          bytes.length > 3 &&
          ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
              (bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0));
      if (!wav && !mp3) {
        throw const ApiFailure('服务未返回 WAV / MP3 音频，请检查接口和音频格式');
      }
      return SpeechAudio(bytes, wav ? 'wav' : 'mp3');
    } on TimeoutException {
      throw const ApiFailure('语音服务响应超时，请稍后重试');
    } on http.ClientException {
      throw const ApiFailure('无法连接语音服务，请检查地址、网络与证书');
    } finally {
      client.close();
      if (identical(client, _active)) _active = null;
    }
  }
}
