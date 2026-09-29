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
  String? siteCookie;

  void cancel() {
    _active?.close();
    _active = null;
  }

  Future<SpeechAudio> synthesize(RoomSettings settings, String text) async {
    cancel();
    final provider = settings.option('ttsProvider', 'openai-compatible');
    var uri = ['openai', 'openai-compatible', 'custom'].contains(provider)
        ? compatibleEndpoint(settings.ttsUrl, speech: true)
        : endpointUri(settings.ttsUrl);
    if (settings.ttsModel.isEmpty && provider != 'gpt-sovits') {
      throw const ApiFailure('请填写语音模型');
    }
    final client = _clientFactory();
    _active = client;
    try {
      var method = 'POST';
      final headers = <String, String>{
        'Content-Type': 'application/json',
        if (settings.ttsKey.isNotEmpty)
          'Authorization': 'Bearer ${settings.ttsKey}',
      };
      Map<String, dynamic> body = {
        'model': settings.ttsModel,
        'input': text,
        'voice': settings.voice,
        'response_format': settings.ttsFormat,
      };
      final lang = settings.option('textLang', 'auto');
      if (provider == 'mimo') {
        headers.remove('Authorization');
        headers['api-key'] = settings.ttsKey;
        body = {
          'model': settings.ttsModel,
          'messages': [
            {'role': 'user', 'content': '只朗读下面的原文，语气温柔自然。不要翻译、解释或朗读动作与舞台提示。'},
            {'role': 'assistant', 'content': text},
          ],
          'modalities': ['audio'],
          'audio': {'format': 'wav', 'voice': settings.voice},
        };
      } else if (provider == 'minimax') {
        body = {
          'model': settings.ttsModel,
          'text': text,
          'stream': false,
          'language_boost':
              const {
                'ja': 'Japanese',
                'en': 'English',
                'zh': 'Chinese',
                'yue': 'Chinese,Yue',
                'ko': 'Korean',
                'auto': 'auto',
              }[lang] ??
              'auto',
          'voice_setting': {
            'voice_id': settings.voice,
            'speed': 1,
            'vol': 1,
            'pitch': 0,
          },
          'audio_setting': {
            'sample_rate': 32000,
            'bitrate': 128000,
            'format': 'mp3',
            'channel': 1,
          },
        };
      } else if (provider == 'elevenlabs') {
        headers.remove('Authorization');
        headers['xi-api-key'] = settings.ttsKey;
        if (!RegExp(r'/text-to-speech/[^/]+/?$').hasMatch(uri.path)) {
          uri = uri.replace(
            path:
                '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/${settings.voice}',
          );
        }
        body = {'text': text, 'model_id': settings.ttsModel};
      } else if (provider == 'gpt-sovits') {
        for (final pair in {
          'gptWeightPath': 'set_gpt_weights',
          'sovitsWeightPath': 'set_sovits_weights',
        }.entries) {
          final weight = settings.option(pair.key);
          if (weight.isEmpty) continue;
          final req = http.Request(
            'GET',
            uri.replace(
              path: '/${pair.value}',
              queryParameters: {'weights_path': weight},
            ),
          )..followRedirects = false;
          final res = await client
              .send(req)
              .timeout(const Duration(seconds: 70));
          await res.stream.drain<void>().timeout(const Duration(seconds: 10));
          if (res.statusCode != 200) {
            throw providerFailure('GPT-SoVITS 权重加载', res.statusCode);
          }
        }
        method = 'GET';
        headers.remove('Authorization');
        final autoLang = RegExp(r'[ぁ-ヿ]').hasMatch(text)
            ? 'ja'
            : RegExp(r'[一-鿿]').hasMatch(text)
            ? 'zh'
            : RegExp(r'[가-힯]').hasMatch(text)
            ? 'ko'
            : 'en';
        uri = uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            'text': text,
            'text_lang': lang == 'auto' ? autoLang : lang,
            'ref_audio_path': settings.option('refAudioPath', settings.voice),
            'prompt_text': settings.option('promptText'),
            'prompt_lang': settings.option('promptLang', 'ja'),
            'text_split_method': 'cut5',
            'batch_size': '1',
            'media_type': 'wav',
            'streaming_mode': 'false',
            'parallel_infer': 'true',
          },
        );
      }
      if (settings.flag('ttsProxy') && provider != 'gpt-sovits') {
        uri = endpointUri(settings.siteUrl).resolve('/api/tts');
        headers.remove('Authorization');
        headers.remove('xi-api-key');
        headers.remove('api-key');
        headers.addAll({
          'Origin': uri.origin,
          'X-Requested-With': 'XMLHttpRequest',
          'Cookie': ?siteCookie,
        });
        body = {
          'enabled': true,
          'provider': provider,
          'apiUrl': settings.ttsUrl,
          'apiKey': settings.ttsKey,
          'model': settings.ttsModel,
          'voice': settings.voice,
          'textLang': lang,
          'text': text,
        };
      }
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (method == 'POST') request.body = jsonEncode(body);
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
      var bytes = builder.takeBytes();
      if ((response.headers['content-type'] ?? '').contains(
        'application/json',
      )) {
        final value = jsonDecode(utf8.decode(bytes));
        final audio = value['choices']?[0]?['message']?['audio'];
        final raw = audio is String
            ? audio
            : audio?['data'] ??
                  value['audio']?['data'] ??
                  value['data']?['audio'];
        if (raw is! String || raw.isEmpty) {
          throw const ApiFailure('语音服务未返回音频数据');
        }
        final encoded = raw.replaceFirst(RegExp(r'^data:[^;,]+;base64,'), '');
        bytes =
            RegExp(r'^[0-9a-fA-F]+$').hasMatch(encoded) && encoded.length.isEven
            ? Uint8List.fromList([
                for (var i = 0; i < encoded.length; i += 2)
                  int.parse(encoded.substring(i, i + 2), radix: 16),
              ])
            : base64Decode(encoded);
      }
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
    } on FormatException {
      throw const ApiFailure('语音服务返回无效音频数据');
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
