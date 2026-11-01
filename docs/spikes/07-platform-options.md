# Spike #18: newest platform options (1-hour tries)

Status: **two yes, one not now.** Run on an iPhone 13 Pro Max (A15, iOS 27.2) in airplane mode, recorded by
the app as "offline (no network path)". Raw data: results/platform-options-iphone13promax.json.

| Question | Answer |
|---|---|
| Offline translation, numbers kept? | **Yes**: 21 languages, the French debrief to English in 0.45 s, every number right |
| Our own model behind Apple's language-model API, on a phone without Apple Intelligence? | **Yes**, about 0.2 s overhead after the first call; **not now** for production |
| LiDAR good enough to measure a road width? | **Not now**: supporting evidence only, answered from published studies |

## 1. Offline translation
- Apple's `Translation` framework lists **21 languages** on this phone (Arabic, Chinese, French, Hindi,
  Portuguese, Spanish, Ukrainian and more). Each must be **downloaded once** while online.
- The #14 French debrief script, translated sentence by sentence, scored with the #14 key-facts scorer
  against the English answer key: **10/11 facts, 17 of 17 sentences, 0.45 s** (1.26 s first run).
- **Every number came through right** (km 18, 4.9 m, 7 m, $480,000, $8.5 million, 85 percent, both dates).
  The one miss is wording: "32 **out of** 64 kilometers" against the key's "32 of 64".
- The `lowLatency` and `highFidelity` strategies gave identical text; high fidelity likely needs Apple
  Intelligence and falls back here (not proven).
- **The in-app download did not start** (`translationTask` + `prepareTranslation` logged nothing); French was
  installed from Settings > Apps > Translate. Production needs a working in-app download or a setup step.

## 2. Our model behind Apple's language-model API
- iOS 27 adds a public `LanguageModel` + `LanguageModelExecutor` protocol (WWDC26 session 339, still beta).
  A wrapper of about 50 lines put our MLX model (LFM2.5 1.2B, spike #12) behind `LanguageModelSession`.
- **It works on this phone** although Apple reports its own model as `unavailable(deviceNotEligible)`.
- Spike #12 prompt, 3 runs: direct 3.64 / 3.70 / 4.06 s, through the session 4.84 / 3.88 / 4.04 s. The
  first call pays about 1.2 s of setup; after that the overhead is about 0 to 0.2 s.
- **Not now for production:** the API is beta, and our constrained JSON output (spike #13, ADR 0005) would
  have to be rebuilt as the executor's guided generation. Our own engine protocol (ADR 0004) already gives
  the model swap. Revisit when the API leaves beta.

## 3. LiDAR measuring
- The phone has LiDAR (tried with Apple's Measure app). Published tests: about **1-2 cm** held still at short
  range, up to about **10 cm** on bigger spans, and up to **±30 cm for lengths over 4 m** when moving; range
  about 5 m. No peer-reviewed study of the Measure app against a tape was found.
- A 4.9 m road against a 7 m spec is a 2.1 m gap, far above 30 cm, so a phone measurement with a photo is
  good **supporting** evidence. A 7 m road is beyond range, and the tape stays the official measurement.
- **Not measured on our phone:** a tape-vs-phone test (3 distances x 3 tries, plus one outdoors) is left
  for a real deployment.
- Sources: [SAE 2021](https://saemobilus.sae.org/articles/bias-repeatability-measurements-3d-scans-made-using-ios-based-lidar-2021-01-0891),
  [indoor modeling study](https://dlib.si/URN:NBN:SI:doc-2N3WGJH4/EDM),
  [ISPRS 2024](https://isprs-archives.copernicus.org/articles/XLVIII-2-W8-2024/431/2024/),
  [Taylor & Francis 2024](https://www.tandfonline.com/doi/full/10.1080/16874048.2024.2408839).

## Decision
1. **Offline translation: GO** as a feature for a later phase (debriefs and documents in another language),
   with the same rule as speech: a translated number keeps a link to its original text.
2. **Custom model behind Apple's API: not now.** Keep our engine protocol; revisit when the API leaves beta.
3. **LiDAR: not now.** Supporting evidence at most; the tape stays official.
