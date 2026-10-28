import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'api.dart';
import 'bindings.dart';

StudioRuntime createStudioRuntime(String source) => _NativeStudio(source);

class _NativeStudio implements StudioRuntime, Finalizable {
  _NativeStudio(String source) {
    _pointer = using(
      (arena) => studioCreate(
        source.toNativeUtf8(allocator: arena).cast(),
        utf8.encode(source).length,
      ),
    );
    if (_pointer == nullptr || studioReady(_pointer) != 1) {
      final error = studioError(_pointer).cast<Utf8>().toDartString();
      studioDestroy(_pointer);
      _pointer = nullptr;
      throw StateError(error);
    }
    _finalizer.attach(this, _pointer, detach: this);
  }
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      studioDestroy,
    ),
  );
  late Pointer<Void> _pointer;
  @override
  Map<String, dynamic> invoke(Map<String, dynamic> command) {
    if (_pointer == nullptr) {
      throw StateError('Studio motion runtime is disposed');
    }
    final json = jsonEncode(command);
    return using((arena) {
      final result = studioCall(
        _pointer,
        json.toNativeUtf8(allocator: arena).cast(),
        utf8.encode(json).length,
      );
      if (result == nullptr) {
        throw StateError(studioError(_pointer).cast<Utf8>().toDartString());
      }
      return (jsonDecode(result.cast<Utf8>().toDartString()) as Map)
          .cast<String, dynamic>();
    });
  }

  @override
  void dispose() {
    if (_pointer == nullptr) return;
    _finalizer.detach(this);
    studioDestroy(_pointer);
    _pointer = nullptr;
  }
}
