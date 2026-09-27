import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'models.dart';
import 'tts_client.dart';

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
      var size = b.getUint32(p + 4, Endian.little);
      // Streaming WAV commonly uses an unknown-length sentinel. Finalize it
      // after the HTTP body completes so native decoders can seek correctly.
      if (label(p) == 'data' && size == 0xffffffff) {
        size = bytes.length - p - 8;
        b.setUint32(p + 4, size, Endian.little);
        b.setUint32(4, bytes.length - 8, Endian.little);
      }
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
  final _tts = TtsClient();
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
    _tts.cancel();
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
    final audio = await _tts.synthesize(settings, text);
    if (generation != _generation || _disposed) return;
    if (audio.format == 'wav') {
      try {
        _envelope = WavEnvelope.parse(audio.bytes);
      } on FormatException {
        // Native players can decode more WAV encodings than the lip analyzer.
        _envelope = null;
      }
    }
    _position = Duration.zero;
    _clock.reset();
    try {
      await _player.play(BytesSource(audio.bytes, mimeType: audio.mimeType));
    } catch (_) {
      throw const ApiFailure('音频已生成但无法播放，请切换 WAV / MP3 格式后重试');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _tts.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }
}
