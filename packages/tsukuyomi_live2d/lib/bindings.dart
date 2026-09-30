// Hand-maintained bindings for the narrow ABI in src/bridge.cpp.
import 'dart:ffi';

@Native<
  Int32 Function(Pointer<Uint8>, Int32, Pointer<Float>, Int32, Pointer<Double>)
>(symbol: 'ts_audio_envelope')
external int nativeAudioEnvelope(
  Pointer<Uint8> bytes,
  int size,
  Pointer<Float> levels,
  int capacity,
  Pointer<Double> duration,
);

final class NativeMesh extends Struct {
  @Int32()
  external int vertices;
  @Int32()
  external int indices;
  @Int32()
  external int texture;
  @Int32()
  external int order;
  @Int32()
  external int flags;
  @Int32()
  external int visible;
  @Int32()
  external int maskCount;
  @Float()
  external double opacity;
  external Pointer<Float> positions;
  external Pointer<Float> uvs;
  external Pointer<Uint16> triangles;
  external Pointer<Int32> masks;
  @Array(4)
  external Array<Float> multiply;
  @Array(4)
  external Array<Float> screen;
}

@Native<Int32 Function()>(symbol: 'ts_available')
external int nativeAvailable();
@Native<Pointer<Void> Function(Pointer<Uint8>, Int32, Pointer<Uint8>, Int32)>(
  symbol: 'ts_create',
)
external Pointer<Void> nativeCreate(
  Pointer<Uint8> bytes,
  int size,
  Pointer<Uint8> physics,
  int physicsSize,
);
@Native<Void Function(Pointer<Void>)>(symbol: 'ts_destroy')
external void nativeDestroy(Pointer<Void> model);
@Native<Void Function(Pointer<Void>)>(symbol: 'ts_begin')
external void nativeBegin(Pointer<Void> model);
@Native<Void Function(Pointer<Void>, Pointer<Char>, Float, Int32)>(
  symbol: 'ts_parameter',
)
external void nativeParameter(
  Pointer<Void> model,
  Pointer<Char> id,
  double value,
  int blend,
);
@Native<Void Function(Pointer<Void>, Float)>(symbol: 'ts_update')
external void nativeUpdate(Pointer<Void> model, double delta);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ts_mesh_count')
external int nativeMeshCount(Pointer<Void> model);
@Native<Int32 Function(Pointer<Void>, Int32, Pointer<NativeMesh>)>(
  symbol: 'ts_mesh',
)
external int nativeMesh(
  Pointer<Void> model,
  int index,
  Pointer<NativeMesh> out,
);
