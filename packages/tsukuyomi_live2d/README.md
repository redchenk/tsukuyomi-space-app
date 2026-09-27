# tsukuyomi_live2d

A small native Cubism model/physics adapter and Flutter triangle renderer.

The FFI ABI is maintained in `src/bridge.cpp` and `lib/bindings.dart`. Flutter's
native-assets build hook compiles the C++ adapter and links the local official
Core static library. The renderer consumes deformed meshes without a WebView.

Only instantiate and update models on the Flutter UI isolate. The Cubism
Framework allocator and lifecycle are process-global; concurrent isolates are
not supported in this prototype. Dispose the model to free all native buffers,
parameter IDs and Flutter image resources.

Run the root project's `tool/setup_live2d.py` to prepare the SDK and model. When
the selected SDK/platform ABI is absent, the library reports `nativeAvailable=0`;
the app displays a clearly labelled illustration preview. Changing SDK availability
requires `flutter clean` before rebuilding.

macOS arm64 native rendering is tested. Build selection also covers macOS x64,
Android, iOS, Windows x86/x64, and Linux x64, but those native Cubism targets still
need platform validation. Windows arm64 and Linux arm64 use the unavailable path
because this SDK package does not include matching Core libraries. Web uses the
Dart unavailable adapter.

Cubism Core/Framework code and binaries are not committed. The Flutter raster
path is a prototype and does not implement Cubism 5.3 advanced/offscreen blending,
which is rejected at load time instead of silently misrendering.
