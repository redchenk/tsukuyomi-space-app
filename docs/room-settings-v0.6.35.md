# Room settings v0.6.35

Website taxonomy: llm, tts, knowledge, memory, model, diary, mcp and debug. The default route opens a native overview, and the first-use wizard and section deep links remain supported. All existing category forms and service handlers remain in place; visited categories retain their widget state.

The compact footer saves all categories. Native back returns to the overview, then offers save, discard or continue editing before leaving. Search opens and focuses real controls. Room exposes a text-labeled settings button on both mobile and desktop.

TTS presets are grouped into official, personal and local services, with independent in-memory drafts. Fish Audio has its own direct and proxy transport, validated voice/model, Japanese translation through the existing voice service, expression-driven emotion cues and official account binding. Official status, model restrictions, price and availability remain server-authoritative. Replay keys distinguish Fish model/emotion while keeping existing GPT-SoVITS replay behavior.

Character Card V2 JSON import/export and world-book editing are bounded reference data. Independent switches reach actual LLM requests, and configuration is scoped to site origin and account. Unsupported scripts, system overrides and example conversations are never executed or injected as history. Keyword, secondary-key logic, spoiler exclusions, history scan depth, ordering and prompt budget are preserved. The native dialogue rules and reference assets are regenerated from the current website sources.

Regression coverage includes real client request capture, card/world-book combinations, account isolation, Fish model/emotion identity, 320/390/1280px navigation and draft persistence; the existing full suite covers models, memory, diary, tools, games and UI locales. Installer and emulator checks remain required by release.yml. Physical-device audio listening is a separate acceptance boundary.

The Beijing distribution transport keeps the fixed receiver and pinned SSH host verification. Only TCP segment size is limited to the previously verified 1200-byte value to avoid the full-sized-segment stalls encountered during v0.6.34 distribution.
