import 'dart:typed_data';

class NativeAudioEnvelope {
  const NativeAudioEnvelope(this.levels, this.duration);
  final List<double> levels;
  final Duration duration;
}

Future<NativeAudioEnvelope?> decodeAudioEnvelope(Uint8List bytes) async => null;
NativeAudioEnvelope? decodeAudioEnvelopeSync(Uint8List bytes) => null;
