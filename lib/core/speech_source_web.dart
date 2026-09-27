import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

class SpeechSource {
  Future<Source> prepare(Uint8List bytes, String format) async => BytesSource(
    bytes,
    mimeType: format == 'wav' ? 'audio/wav' : 'audio/mpeg',
  );
  Future<void> dispose() async {}
}
