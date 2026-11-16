import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'models.dart';

/// A bounded, in-memory 16 kHz mono WAV; never writes recordings to disk.
class RoomVoiceInput {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _stream;
  Timer? _timer;
  final _bytes = BytesBuilder(copy: false);
  int _epoch = 0;
  Future<void> start(void Function() onLimit) async {
    await cancel();
    final epoch = _epoch;
    final recorder = AudioRecorder();
    _recorder = recorder;
    try {
      if (!await recorder.hasPermission()) {
        throw const ApiFailure('请允许使用麦克风后重试');
      }
      if (epoch != _epoch) return;
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      if (epoch != _epoch) {
        await recorder.stop();
        return;
      }
      _stream = stream.listen((chunk) {
        if (epoch != _epoch) return;
        final available = 120 * 16000 * 2 - _bytes.length;
        if (available > 0) {
          _bytes.add(chunk.sublist(0, chunk.length.clamp(0, available)));
        }
        if (chunk.length >= available) onLimit();
      }, onError: (Object _) => onLimit());
      _timer = Timer(const Duration(seconds: 120), onLimit);
    } catch (_) {
      await cancel();
      rethrow;
    }
  }

  Future<Uint8List> stop() async {
    _timer?.cancel();
    _timer = null;
    await _recorder?.stop();
    await _stream?.cancel();
    _stream = null;
    final pcm = _bytes.takeBytes();
    final recorder = _recorder;
    _recorder = null;
    await recorder?.dispose();
    if (pcm.isEmpty) throw const ApiFailure('没有录到声音，请重试');
    return wav(pcm);
  }

  Future<void> cancel() async {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    final stream = _stream;
    _stream = null;
    await stream?.cancel();
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } finally {
        await recorder.dispose();
      }
    }
    _bytes.clear();
  }

  static Uint8List wav(Uint8List pcm) {
    final result = Uint8List(44 + pcm.length), header = ByteData(44);
    void ascii(int offset, String text) {
      result.setRange(offset, offset + text.length, text.codeUnits);
    }

    header.setUint32(4, pcm.length + 36, Endian.little);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    header.setUint32(40, pcm.length, Endian.little);
    result.setRange(0, 44, header.buffer.asUint8List());
    ascii(0, 'RIFF');
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    ascii(36, 'data');
    result.setRange(44, result.length, pcm);
    return result;
  }
}
