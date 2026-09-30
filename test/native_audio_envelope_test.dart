import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_live2d/tsukuyomi_live2d.dart';
import 'package:tsukuyomi_space_app/core/voice_service.dart';

void main() {
  test('native MP3 decoder distinguishes silence from actual PCM energy', () {
    final decoded = decodeAudioEnvelopeSync(
      File('test/fixtures/lips-silence-tone.mp3').readAsBytesSync(),
    )!;
    expect(decoded.duration.inMilliseconds, inInclusiveRange(990, 1150));
    expect(decoded.levels.take(20).every((v) => v < .001), isTrue);
    expect(decoded.levels.skip(32).take(10).every((v) => v > .7), isTrue);
    expect(decoded.levels.every((v) => v.isFinite && v >= 0 && v <= 1), isTrue);
  });

  test('native WAV windows match the existing PCM envelope', () {
    final bytes = File('test/fixtures/lips-silence-tone.wav').readAsBytesSync();
    final decoded = decodeAudioEnvelopeSync(bytes)!;
    final dart = WavEnvelope.parse(bytes);
    expect(decoded.duration, dart.duration);
    expect(decoded.levels.length, dart.levels.length);
    for (var i = 0; i < dart.levels.length; i++) {
      expect(decoded.levels[i], closeTo(dart.levels[i], .00001));
    }
  });

  test(
    'isolate decoding returns real MP3 levels without blocking the UI',
    () async {
      final decoded = await decodeAudioEnvelope(
        File('test/fixtures/lips-silence-tone.mp3').readAsBytesSync(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.levels.take(20), everyElement(lessThan(.001)));
      expect(decoded.levels.skip(32).take(10), everyElement(greaterThan(.7)));
    },
  );

  test('native decoder rejects truncated and unrelated audio safely', () {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList('not an audio file'.codeUnits),
      Uint8List.fromList('RIFF0000WAVE'.codeUnits),
    ]) {
      expect(decodeAudioEnvelopeSync(bytes), isNull);
    }
  });
}
