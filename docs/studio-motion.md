# Native Studio motion

The App's Room, fullscreen character and Live2D director execute the real
Yachiyo Live2D Studio motion system, pinned to upstream commit
`7cfc08a328be332d3b876a4257e74f8411f08d5f`. Thirteen unchanged source modules
cover the performance brain, character state, semantic action registry,
expression presets, natural blinking, behavior arbitration, streaming speech
handoffs and tracking-to-Cubism rig mapping. File hashes and original licenses
are retained in `third_party/yachiyo-live2d-studio/SOURCE.json`.

`tool/studio_motion/bundle.mjs` bundles only that dependency graph, without npm
or a running server. The generated JS and notices are checked in and included
in every installer's asset verification. The browser UI, Studio's servers,
VTube Studio transport and providers are not embedded.

## Execution and rendering

`tsukuyomi_studio_motion` builds pinned QuickJS-NG 0.17.0 as a Flutter native
asset on desktop, Android, iOS and the existing OHOS cross toolchain. The realm
has no libc, network, filesystem, module loader or host callbacks. The only
entrypoint accepts bounded JSON data; no user or model response is evaluated
as code. Memory is limited to 32 MiB, stack to 1 MiB and each invocation to
50 ms. Source initialization has a separate two-second bound.

CharacterStage owns the runtime together with its model. The existing scene
clock drives Studio only on active frames; pause, hidden routes, minimization
and renderer backpressure do not advance it. Fullscreen shares the same
runtime. Model reload/disposal detaches and frees the old instance. A model
load failure remains visible and retryable without blocking chat.

Studio samples with its upstream Cubism intensity scale of 1.86. Parameter
values **and weights** pass to the existing native Cubism renderer. Canvas,
Metal, OpenGL, D3D and JNI use the same blend encoding: 0/1/2 still mean
set/add/multiply, while bit 16 selects weighted set with a 16-bit weight.
Legacy idle waves and expression-file overlays are disabled on Studio frames
to avoid competing drivers. The viewport and room background stay fixed.

The native App's existing audio playback clock remains authoritative for
mouth opening. Its amplitude also feeds Studio's speaking gestures and
release transition; pauses remain silent. Thinking status and streaming
speech intents enter the upstream state machine. No extra LLM or TTS request
is made. Explicit App rig controls and queue/delay limits remain available.

## Verification

```sh
node tool/studio_motion/bundle.mjs --check
node --experimental-vm-modules tool/studio_motion/reference.mjs --check
flutter test test/studio_motion_test.dart test/live2d_scene_controller_test.dart
flutter run -d macos -t tool/verify_studio_motion.dart
```

The reference generator imports the unmodified upstream ESM directly and
compares it with the shipped bundle over 910 commands / 900 frames. Flutter
then checks the native QuickJS results against those same reference frames.
Tests also cover all 24 semantic actions, queue/protection/replacement,
speech release, weighted blending, silence, runtime disposal, fullscreen,
background suspension and active interaction.

The native render probe creates 600 Cubism frames and exports 300 PNGs for
review. Its simulated voice is only a rendering fixture, not a TTS quality
claim. Host measurements do not establish physical Android frame rate;
device acceptance should include K90 chat, automatic reading, keyboard,
fullscreen, background/resume and a prolonged conversation.
