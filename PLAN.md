# LocalFlow — build plan

Private, fully local push-to-talk dictation for macOS: hold Right Option → speak → release → Parakeet (Core ML / ANE) transcribes → Qwen3 (MLX / GPU) cleans → pasted into the focused field. No network after the one-time model download.

## Layout

| Path | What |
|---|---|
| `Core/` | SwiftPM package `LocalFlowCore` (engine) + `LocalFlowCoreTests`. Depends on FluidAudio 0.17.5 and mlx-swift-lm 3.32.3 (pinned, `exact:`). |
| `App/` | `LocalFlow.app` menu bar target (SwiftUI `MenuBarExtra`, `LSUIElement`). |
| `CLI/` | `localflow-cli` tool target: `--file`, `--eval`, `--download`, `--bench`. |
| `project.yml` | XcodeGen spec → `LocalFlow.xcodeproj` (generated, gitignored). |
| `eval/` | `cases.jsonl` (32 cases), `audio/` (synthesized WAVs, gitignored). |
| `scripts/` | `build.sh` (generate → build → sign → install), `synth-audio.sh`. |
| `build/DerivedData` | all build output (delete freely). |

Models live in `~/Library/Application Support/LocalFlow/models/` (STT: `parakeet-tdt-0.6b-v3-coreml/`, LLM: HF layout under `models/<org>/<repo>/`). Config: `~/Library/Application Support/LocalFlow/config.json`. Log: `~/Library/Logs/LocalFlow/localflow.log`.

## Decisions made up front

- Every build goes through `xcodebuild` (SwiftPM CLI cannot compile mlx-swift's Metal shaders). `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on every call; the Metal Toolchain component was missing and was installed with `xcodebuild -downloadComponent MetalToolchain` (no sudo, 688 MB).
- Swift 6 compiler, Swift 5 language mode in our targets (dependencies compile in their own modes).
- Pure logic (config, guardrails, chunker, hotkey state machine, vocabulary pass) has no ML dependency and is unit-tested first.
- STT: `AsrModels.loadLocal(from:)` (synchronous, never touches the network) for every normal launch; `AsrModels.download(to:)` only in the explicit download step. `ModelHub.offlineMode = true` at launch as a hard guard.
- LLM: load from the local directory only; the HF hub client is used only in the download step. Greedy sampling, `maxTokens = min(2×input+64, 2048)`, GPU cache limit set.
- Vocabulary: injected into the prompt as "Preferred spellings" and enforced by a deterministic post-pass. FluidAudio's custom-vocabulary boosting needs a separate English-only CTC model, so it is not wired in (documented).
- Signing: an "Apple Development" identity exists in the keychain → manual signing with it (auto-detected into Signing.xcconfig), hardened runtime, audio-input entitlement, no sandbox.

## Phases and verification

| # | Phase | Verify |
|---|---|---|
| 1 | Toolchain + deps build | `xcodebuild build -scheme localflow-cli` succeeds; pure-logic tests pass (`swift test` on the dep-free manifest, then `xcodebuild test`). |
| 2 | STT on a WAV | `scripts/synth-audio.sh` → `localflow-cli --file eval/audio/case-1.wav` prints a sensible raw transcript with ms timing. |
| 3 | LLM cleanup + eval | `localflow-cli --eval eval/cases.jsonl --model <id>` for Qwen3-4B-Instruct-2507-4bit, Qwen3-1.7B-4bit, and a Qwen3.5 ~4B instruct build if one exists. Iterate the prompt until the shipped model ≥90% and cases 1/7/8/9/17 pass. Prove prefix-cache gain with before/after timings. |
| 4 | CLI end-to-end | `--file` on all synthesized cases prints raw → cleaned with per-stage timings; warm latency for a ~10 s utterance measured. |
| 5 | Menu bar app | Builds, runs, icon in three states, hotkey tap, paste with clipboard restore, Esc cancel, permissions surfaced in the status line. Manual: permission dialogs. |
| 6 | Sign, install, login item | `scripts/build.sh` installs to `~/Applications/LocalFlow.app`; `codesign -dv` shows the identity; `lsof -i -P \| grep -i localflow` empty during dictation; launch at login toggled via `SMAppService`. |

## Risks

- mlx-swift compile time and DerivedData size on 13 GB free → single DerivedData under `build/`, Release for products, Debug only for tests.
- Prefix KV-cache reuse depends on what mlx-swift-lm exposes; if it cannot be reused safely, keep the prompt short and report the real numbers.
- Qwen3 may answer questions instead of cleaning them (cases 7/8/17) → the `<transcript>` framing plus guardrails; iterate.
- Right Option as a modifier arrives via `flagsChanged` only; Fn needs the user's "Press 🌐 key to → Do Nothing" setting.
- Automatic signing could try to reach the developer portal → manual signing with the local identity.

## Build log (2026-10-06, what actually happened)

- Disk: 14 GB free at start → 2.3 GB at the low point (DerivedData 5.4 GB + models 2.6 GB + a 2 GB macOS sleepimage written while the battery hit 1 %) → 15.9 GB after macOS reclaimed the sleepimage. Qwen3.5-4B (3.06 GB) was skipped at the low point.
- The Mac was on battery, discharging from 2 % to 1 %, for ~20 minutes mid-build; the GPU was throttled 2–3× (LLM 417 ms → 990 ms p50 on identical input). All reported numbers come from AC power.
- Metal Toolchain was missing (Xcode 26 ships without it): `xcodebuild -downloadComponent MetalToolchain`, no sudo.
- Signing failed once: the certificate's team ID is its OU field, not the ID in parentheses in its common name; build.sh now reads the OU.
- mlx-swift-lm 3.x no longer depends on swift-transformers/Hub; added swift-huggingface + swift-transformers and inlined the two bridge structs the `MLXHuggingFace` macros expand to (no macro plugin needed).
- FluidAudio names the Parakeet folder `parakeet-tdt-0.6b-v3` (not the repo name) and `download(to:)` always writes to `<parent>/<folderName>`; the Transcriber now uses that name.
- swift-huggingface 0.9.0 throws `snapshotRequiresCacheOrDestination` *after* a complete no-cache download; caught and verified by file presence.
- Prompt rounds: 84.4 % → 81.2 % → 84.4 % → **100 %**. The model would not reliably drop a leading "So"/"este bueno" or produce a blank line for "new paragraph", so both moved into code (`LeadingFillers`, `SpokenBreaks`).
- Qwen3-1.7B-4bit: 62.5 %, failed must-pass (#9 kept the corrected span, #17 obeyed the injection); deleted.
- Tests: 65 via `xcodebuild test` (Release, public API only, no `@testable`), after fixing two `await`-in-autoclosure lines.
- First app launch: STT load 39.9 s (ANE specialization for the new binary), LLM 12.2 s; second launch: STT 191 ms, LLM 6.7 s.
- Latency target (< 1.0 s for a 10 s utterance) missed at ≈ 1.3 s; the decode speed (~30 tok/s) is the M2's ceiling for a 4B 4-bit model. Details in README.

## Round 2 (same day): Settings window + public repo prep
- `App/SettingsView.swift`: four tabs (General, Cleanup, Models, Privacy) covering every config key; toggles/pickers/steppers apply immediately through `AppController.applyConfig`, text fields on Apply. Opened via ⌘, / "Settings…" / `localflow-cli --settings` (distributed notification → SwiftUI `openSettings`; `NSApp.sendAction(showSettingsWindow:)` did not work from a window-less status-item app).
- Verified with cua-driver (AX automation): 23 checks across the tabs; every change read back from config.json, prefix cache rebuilt after a vocabulary edit, Reload refreshes the editor.
- Public-repo sanitization: generic default vocabulary, eval names changed, signing moved to a gitignored `Signing.xcconfig` auto-written by build.sh (identity + OU team), private brief moved to `.local/`. Eval with the generic list: 31/32 (case 20 drops "for").
