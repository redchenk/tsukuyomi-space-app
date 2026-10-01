# Third-party notices

This distribution includes Live2D Cubism Core and Native Framework 5 R5.
Copyright (c) Live2D Inc. All rights reserved.

- Core: https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html
- Framework: https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html
- SDK release terms: https://www.live2d.com/en/sdk/license/

The SDK source archive is downloaded from Live2D during builds and is not redistributed here. The application embeds the runtime components required to display the character.

The character model, expressions, textures, room artwork and application launcher icon are from the owner's tsukuyomi-space project:
https://github.com/redchenk/tsukuyomi-space
The original artwork and character rights remain with their respective owners. This preview release does not grant permission to reuse those assets in other products.

The bundled Wiki artwork, Yachiyo guide sprites, game project, costumes, fonts
and audio are also taken from that original project. Their source and native
conversion details are recorded in assets/game/README.md; all original rights
remain with their respective creators.

The native WAV/MP3 envelope decoder uses dr_libs by David Reid under its MIT
license. The complete license is included in
packages/tsukuyomi_live2d/src/vendor/dr_libs/LICENSE.

Flutter, Dart and third-party Dart packages retain their respective licenses. Flutter's generated NOTICES file in the application's asset bundle contains dependency notices.

## Desktop Agent runtimes (0.6)

Desktop distributions include unmodified [OpenCode v1.18.33](https://github.com/anomalyco/opencode/releases/tag/v1.18.33) (MIT, Copyright 2025 opencode) and [OpenAI Codex 0.159.0](https://github.com/openai/codex/releases/tag/rust-v0.159.0) (Apache-2.0, Copyright 2025 OpenAI). OpenCode's MIT license and Codex's license/NOTICE are copied into each runtime bundle's `licenses/` directory. Bundled Codex package helpers retain their upstream attribution. Upstream source and build inputs remain available at the pinned tags. The small POSIX process supervisor is project code. macOS binaries receive an ad-hoc signature for packaging; runtime-manifest.json is regenerated after signing and records the final distributed bytes.
