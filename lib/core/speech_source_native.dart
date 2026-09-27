import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

/// A real extension lets AVFoundation/GStreamer select their native decoder.
/// Each request owns its temporary directory, removed after stop/disposal.
class SpeechSource {
  Directory? _directory;
  Future<Source> prepare(Uint8List bytes, String format) async {
    final directory = await Directory.systemTemp.createTemp('tsukuyomi-tts-');
    _directory = directory;
    final file = File('${directory.path}/speech.$format');
    await file.writeAsBytes(bytes, flush: true);
    return DeviceFileSource(file.path);
  }

  Future<void> dispose() async {
    final directory = _directory;
    _directory = null;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}
