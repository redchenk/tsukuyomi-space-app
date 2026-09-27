import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class WavEnvelope {
  WavEnvelope(this.levels, this.duration);
  final List<double> levels;
  final Duration duration;
  double at(Duration position) => levels.isEmpty
      ? 0
      : levels[(position.inMilliseconds ~/ 20).clamp(0, levels.length - 1)];
  static WavEnvelope parse(Uint8List bytes) {
    final b = ByteData.sublistView(bytes);
    String label(int at) =>
        ascii.decode(bytes.sublist(at, at + 4), allowInvalid: true);
    if (bytes.length < 44 || label(0) != 'RIFF' || label(8) != 'WAVE') {
      throw const FormatException('TTS 必须返回 PCM WAV 音频');
    }
    var channels = 0,
        sampleRate = 0,
        bits = 0,
        format = 0,
        offset = 0,
        length = 0;
    for (var p = 12; p + 8 <= bytes.length;) {
      final size = b.getUint32(p + 4, Endian.little);
      if (p + 8 + size > bytes.length) throw const FormatException('WAV 音频不完整');
      if (label(p) == 'fmt ' && size >= 16) {
        format = b.getUint16(p + 8, Endian.little);
        channels = b.getUint16(p + 10, Endian.little);
        sampleRate = b.getUint32(p + 12, Endian.little);
        bits = b.getUint16(p + 22, Endian.little);
      } else if (label(p) == 'data') {
        offset = p + 8;
        length = size;
      }
      p += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (format != 1 ||
        bits != 16 ||
        channels < 1 ||
        channels > 8 ||
        sampleRate < 8000 ||
        sampleRate > 192000 ||
        length == 0) {
      throw const FormatException('口型分析目前支持 16-bit PCM WAV');
    }
    final frames = length ~/ (channels * 2),
        window = (sampleRate * .02).round();
    final levels = <double>[];
    for (var frame = 0; frame < frames; frame += window) {
      var sum = 0.0, count = 0;
      for (var f = frame; f < math.min(frame + window, frames); f++) {
        for (var channel = 0; channel < channels; channel++) {
          final sample =
              b.getInt16(offset + (f * channels + channel) * 2, Endian.little) /
              32768;
          sum += sample * sample;
          count++;
        }
      }
      levels.add((math.sqrt(sum / count) * 4).clamp(0, 1));
    }
    return WavEnvelope(
      levels,
      Duration(microseconds: (frames / sampleRate * 1000000).round()),
    );
  }
}

abstract class VoiceService extends ChangeNotifier {
  bool get playing;
  double get mouth;
  Future<void> speak(RoomSettings settings, String text);
  Future<void> stop();
}

class AudioVoice extends VoiceService {
  final _player = AudioPlayer();
  final _clock = Stopwatch();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Duration _position = Duration.zero;
  WavEnvelope? _envelope;
  http.Client? _client;
  int _generation = 0;
  bool _disposed = false;
  @override
  bool playing = false;
  AudioVoice() {
    _subscriptions.add(
      _player.onPositionChanged.listen((p) {
        _position = p;
        _clock
          ..reset()
          ..start();
      }),
    );
    _subscriptions.add(
      _player.onPlayerStateChanged.listen((state) {
        playing = state == PlayerState.playing;
        if (playing) {
          _clock.start();
        } else {
          _clock.stop();
        }
        if (!_disposed) notifyListeners();
      }),
    );
  }
  @override
  double get mouth {
    if (!playing || _envelope == null) return 0;
    final p = _position + _clock.elapsed;
    return p >= _envelope!.duration ? 0 : _envelope!.at(p);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _client?.close();
    _client = null;
    playing = false;
    _clock.reset();
    _clock.stop();
    _envelope = null;
    await _player.stop();
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> speak(RoomSettings settings, String text) async {
    await stop();
    if (_disposed) return;
    final generation = _generation;
    final uri = endpointUri(settings.ttsUrl);
    final client = http.Client();
    _client = client;
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
          'voice': settings.voice,
          'input': text,
          'response_format': 'wav',
        });
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw ApiFailure('语音生成失败（HTTP ${response.statusCode}）');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (generation != _generation || _disposed) return;
        if (builder.length + chunk.length > 24 * 1024 * 1024) {
          throw const ApiFailure('语音超过样机大小限制');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      final envelope = WavEnvelope.parse(bytes);
      if (generation != _generation || _disposed) return;
      _envelope = envelope;
      _position = Duration.zero;
      _clock.reset();
      await _player.play(BytesSource(bytes, mimeType: 'audio/wav'));
    } finally {
      client.close();
      if (identical(client, _client)) _client = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _client?.close();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
