# ADR 0004: On-device model choice

- Status: accepted (engine MLX chosen in spike #12, CONFIRMED by spike #13)
- Date: 2026-10-30

## Context
The model must run offline on an iPhone 13 Pro Max (A15, 6 GB RAM, no built-in Apple model) and write
clear notes and report text. A bake-off ran four small models on the real phone in airplane mode with
the same four tests (see docs/bakeoff.md).

## Options
Bake-off results on the real phone, airplane mode:

| Model | Speed on the phone | Notes |
|---|---|---|
| LFM2.5 1.2B | about 38 tokens/s (llama.cpp app) | Fastest; good writing; invented numbers in one app, correct in another |
| Qwen3 1.7B | 13-21 tokens/s | Better with names; invented dates; half the speed |
| SmolLM3 3B | about 14 tokens/s plus thinking time | Best writing; too slow for field use |
| Gemma 3 1B | skipped | Enough evidence from the others |

## Decision
LFM2.5 1.2B as the main model, Qwen3 1.7B as the backup. No "thinking" models and no 3B models on
this phone. The inference engine (llama.cpp vs MLX) is decided in the Iteration 2 spike with identical
settings.

## Why
- Speed matters in the field and in the demo: about 3x faster than the 3B model.
- The weakness that matters (numbers) is removed by design in ADR 0005, so writing quality and speed decide.
- The same model scored differently in two apps, so settings (quantization, temperature) are part of the decision.

## Consequences
- **License:** LFM2.5 ships under its own license, which may require a commercial agreement for large
  organizations; Qwen3 is Apache 2.0. A large organization adopting this should check the terms and can
  switch to the backup with no design change.
- Model files are not stored in the repo; the app downloads them.

## Engine decision (spike #12, Oct 30 2026)
Both engines ran LFM2.5 1.2B inside our own app on the iPhone 13 Pro Max in airplane mode, 12 runs each,
no crash (docs/spikes/01-model-engine.md):

| | llama.cpp b11960 | MLX 3.32.3 |
|---|---|---|
| Decode speed | 35.7 tok/s | 43.6 tok/s |
| First token | 338 ms | 601 ms |
| Load | 12.9 s | 0.9 s |
| Report wording | softened facts | stayed accurate |

**Engine: MLX** (faster, near-instant load, more faithful wording, runtime JSON-schema constraints, a normal
Swift package). **Backup: llama.cpp.** Final confirmation after spike #13 (constrained output, fixed seed).
Both engines are device-only (no iOS Simulator), so production code uses a protocol with a fake in tests.

## Speech engine decision (spike #14, Nov 1 2026)
Both engines ran in airplane mode on the iPhone 13 Pro Max, scored by code (docs/spikes/06-speech.md):

| | Apple SpeechTranscriber | WhisperKit large-v3 |
|---|---|---|
| Real non-native voice, quiet: WER / key facts | 13.5% / 10 of 11 | 8.8% / 11 of 11 |
| Time for about 100 s of audio | about 2 s | 11-23 s |
| In the app | nothing (system language files) | 626 MB, ~100 s first load |
| Same result every run | yes | no (dropout and invented text) |

**Engine: Apple SpeechTranscriber.** **Option: WhisperKit**, behind the same interface, for speakers it
serves better; re-tested in Hardening. Neither is trusted for numbers on its own (ADR 0005).

## Apple's language-model API with our model (spike #18, Nov 1 2026)
iOS 27's `LanguageModel` protocol ran our MLX model through `LanguageModelSession` on the iPhone 13 Pro Max,
offline, although Apple's own model is not available on this phone (about 0.2 s overhead after the first
call; docs/spikes/07-platform-options.md). **Not adopted now:** the API is beta and our constrained JSON
output would need rebuilding. Our own engine protocol stays.

## Revisit when
- A newer small model beats LFM2.5 on the same four tests on the same phone, or licensing requires the switch.
- Apple's `LanguageModel` API leaves beta and supports constrained JSON output for custom models.
- Speech: Apple stops supporting a needed language or device, or a smaller Whisper-class model is repeatable.
