import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsukuyomi_space_app/core/speech_source_native.dart';

void main() {
  test(
    'native audio files retain decoder extension and are removed on disposal',
    () async {
      for (final format in ['wav', 'mp3']) {
        final source = SpeechSource();
        final prepared = await source.prepare(
          Uint8List.fromList([1, 2, 3]),
          format,
        ) as DeviceFileSource;
        final file = File(prepared.path);
        expect(file.path, endsWith('speech.$format'));
        expect(await file.readAsBytes(), [1, 2, 3]);
        expect(prepared.mimeType, isNull);
        await source.dispose();
        expect(await file.parent.exists(), false);
        await source.dispose();
      }
    },
  );
}
