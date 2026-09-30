import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

class NativeAudioEnvelope {
  const NativeAudioEnvelope(this.levels, this.duration);
  final List<double> levels;
  final Duration duration;
}

Future<NativeAudioEnvelope?> decodeAudioEnvelope(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > 40 * 1024 * 1024) return null;
  return Isolate.run(() => decodeAudioEnvelopeSync(bytes));
}

NativeAudioEnvelope? decodeAudioEnvelopeSync(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 40 * 1024 * 1024) return null;
  final input = calloc<Uint8>(bytes.length),
      levels = calloc<Float>(30000),
      duration = calloc<Double>();
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    final count = nativeAudioEnvelope(
      input,
      bytes.length,
      levels,
      30000,
      duration,
    );
    if (count <= 0 || count > 30000 || !duration.value.isFinite) return null;
    return NativeAudioEnvelope(
      List<double>.of(levels.asTypedList(count)),
      Duration(microseconds: (duration.value * 1000).round()),
    );
  } finally {
    calloc.free(input);
    calloc.free(levels);
    calloc.free(duration);
  }
}
