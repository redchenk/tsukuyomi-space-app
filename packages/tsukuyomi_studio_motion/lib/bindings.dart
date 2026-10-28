import 'dart:ffi';

@Native<Pointer<Void> Function(Pointer<Char>, Int32)>(
  symbol: 'ts_studio_create',
)
external Pointer<Void> studioCreate(Pointer<Char> source, int length);
@Native<Void Function(Pointer<Void>)>(symbol: 'ts_studio_destroy')
external void studioDestroy(Pointer<Void> runtime);
@Native<Int32 Function(Pointer<Void>)>(symbol: 'ts_studio_ready')
external int studioReady(Pointer<Void> runtime);
@Native<Pointer<Char> Function(Pointer<Void>)>(symbol: 'ts_studio_error')
external Pointer<Char> studioError(Pointer<Void> runtime);
@Native<Pointer<Char> Function(Pointer<Void>, Pointer<Char>, Int32)>(
  symbol: 'ts_studio_call',
)
external Pointer<Char> studioCall(
  Pointer<Void> runtime,
  Pointer<Char> json,
  int length,
);
