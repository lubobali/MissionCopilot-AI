# Spike #12: model engine, llama.cpp vs MLX

Status: in progress. Device: iPhone 13 Pro Max (A15, 6 GB, iOS 27.2), wired, Debug, free provisioning.
Baseline free memory for an app: 2.98 GB (00-device-baseline.md).

## Pinned inputs (reproducible)
| Item | Version / fingerprint |
|---|---|
| llama.cpp | build **b11960** = stable **v0.8.0** (same commit `8642541b`); `llama-b11960-xcframework.zip` SHA-256 `feba05e0b7cb5e682ae3354abb455bf9723ae2cc95c69e24d073264e6a34d759` |
| GGUF model | `LiquidAI/LFM2.5-1.2B-Instruct-GGUF` revision `8ed288026e23`, file `LFM2.5-1.2B-Instruct-Q4_0.gguf` (664 MB), SHA-256 `2ea801949d760cdf1a2cc04a54262c22c3c0c54f0769d57760c9adeb0e59233f` |
| MLX | `mlx-swift-lm` **3.32.3**, `mlx-swift` 0.32.3, `swift-transformers` 1.3.5 (all versions in `ios/AILab/Package.resolved`) |
| MLX model | `mlx-community/LFM2.5-1.2B-Instruct-4bit` revision `dee2f8a2786e` (633 MB), `model.safetensors` SHA-256 `d837f243744bbdbe7dd032f90b482a1c45d5b6035b25c1d7804d0f4c74b5c004` |

Model files are NOT in the repo (size, licence). They live in the git-ignored `models/` folder.

## Fair-test settings
Same four prompts as the bake-off (T1, T1-FR, T2, T3), 3 repeats each (12 runs per engine);
temperature 0.1, top-k 50, repetition penalty 1.05, max 400 new tokens; fresh conversation per run.

## Findings so far
1. **No iOS Simulator slice** in the official llama.cpp framework (device + macOS only), and MLX does not
   run in the Simulator. Engines therefore live in a **separate AI Lab project** (`ios/AILab`), so the
   main app, its tests and CI stay simulator-friendly. Production code will reach the engine through a
   protocol with a fake in tests.
2. **The stable llama.cpp release (v0.8.0) has no iOS framework**; the matching numbered build b11960
   does. Pinned to that.
3. **llama.cpp C API differs from older examples** (for example `llama_sampler_init_penalties` takes
   5 arguments starting with `n_vocab`); code was written against the pinned header.
4. **Memory safety:** token pointers are only valid inside `withUnsafeMutablePointer` closures, so
   `llama_decode` runs inside them. UTF-8 bytes are collected and decoded once, because accented
   characters (French) can span two tokens.
5. **Build-time macro avoided:** MLX's Hugging Face macro must be trusted to run at build time. Instead
   of skipping that check, a small hand-written tokenizer adapter replaces it (two fewer packages).
   Rule for production: no third-party build-time macros.
6. **Xcode 27 needs the Metal Toolchain** as a separate download for MLX's GPU shaders.

## Results
(pending: tokens/s, time to first token, memory, crashes, output quality per engine)

## Decision
(pending: GO / NO-GO, engine choice -> ADR 0004)
