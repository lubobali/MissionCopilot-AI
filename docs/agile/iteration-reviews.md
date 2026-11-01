# Iteration reviews

One short review at the end of each iteration: what was done, what we learned, what changes next.
This project is built by one developer working with AI coding agents, so iterations are one day.

## Iteration 0 · Foundations (done Oct 30 2026)
**Done:** public repo and private mirror, TDD toolchain (uv, pytest, Ruff, ty, prek hooks), CI on
GitHub with a Linux job and a macOS job, XcodeGen project, first app running on a real iPhone 13 Pro Max,
ADR 0001 (native iOS + Python backend) and ADR 0002 (XcodeGen).

**Learned:**
- A model bake-off on the real phone before any code: LFM2.5 1.2B ran at about 38 tokens per second,
  but every tested model invented numbers. Decision: code does all the math, the model only writes.
- Pinning matters: "ubuntu-latest" was about to move to a new OS, so the runner image is pinned.
- A small warning hid a real problem: tests in one folder ran without the strict settings.
- Hooks must match CI exactly, or local and CI drift apart.

**Next:** Iteration 1 · Architecture.

## Iteration 1 · Architecture (done Oct 30 2026)
**Done:** system context and container diagrams with trust boundaries; data classification with
inherited labels; ADRs 0003-0011; domain model; OpenAPI 3.1 contract with tests; fictional demo dataset
with tests; architecture summary and review; Agile setup (board, Definition of Done, reviews).

**Learned:**
- Guards beat manual checks: the ADR guard caught a heading a manual check missed, and a hook gap would
  have let contract-only changes skip the contract tests.
- CI speed matters: docs-only PRs waited up to 12 minutes for a macOS runner; path filters cut that to
  about 15 seconds.
- Mutation checks (break the data on purpose) prove that tests really protect what they claim.
- The review found an accessibility gap; it is now in the Definition of Done.

**Next:** Iteration 2 · Feasibility spikes on the real iPhone.

## Iteration 2 · Feasibility spikes (done Nov 1 2026)
**Done:** seven spikes on a real iPhone 13 Pro Max (A15, iOS 27.2, no Apple Intelligence), all in airplane
mode, each with a report in docs/spikes/ and raw numbers in docs/spikes/results/. 8 pull requests, CI green.

| Spike | Result |
|---|---|
| #12 Model engine | GO: MLX, 43.6 tokens/s, 0.9 s load (llama.cpp is the backup) |
| #13 Structured output | GO: JSON-schema output 20/20 valid and correct, 3.1 s, vs 0/20 free text |
| #16 Encryption | GO: SQLCipher + iOS file protection + per-mission keys; wrong key, lock and crypto-shred proven |
| #17 Signed evidence | GO: Secure Enclave signs in 20 ms; the phone's hash chain verifies in Python |
| #15 Documents | GO with changes: tables read in 0.19 s per page; scan to 8 checked facts and MC-01 in about 5 s |
| #14 Speech | GO with changes: Apple's transcriber by default, WhisperKit as an option; spoken numbers need confirming |
| #18 Platform options | Translation yes; our model behind Apple's AI API yes (not now); LiDAR not now |

**Learned:**
- **Models are confidently wrong about numbers, every kind of model.** The text model wrote 0 km of 0 km
  from a dark scan; speech engines wrote "$85 million" for 8.5 million and "$8,500". Code caught each one,
  because every spike scored numbers separately from words. Two new rules in ADR 0005: every extracted fact
  must be grounded in its source, and a spoken number is only "heard" until the speaker confirms it.
- **Check the plan before building.** Re-reading research and the SDK first changed four spikes: a weak
  Whisper model swapped for large-v3, a wrong idea to run models in CI dropped, App Attest replaced by
  Secure Enclave device keys (free Apple ID), and the custom-model question answered from SDK headers.
- **Test the test.** Several "results" were my own bugs: a lock test that could not pass, photos sorted by
  name instead of date, a scorer that missed "December 15th", a take that overwrote another, a file copy
  lost to a reinstall. Each was caught, fixed with a test, and written down in the report.
- **Score by code against an answer key generated from the data,** never by eye. It made the spike results
  repeatable and honest.
- **CI must match the developer's tools:** CI built with Xcode 16.4 while development used Xcode 27.2; it is
  now pinned to Xcode 26.6 on macos-26.

**Changed in the plan:**
- Phase 3 (security) uses Secure Enclave device keys instead of App Attest; prompt injection from scanned
  pages and speech goes into the threat model.
- New production rules: grounding, read-back for spoken numbers, offline readiness checks (speech language
  files, translation languages, model files) before a mission.
- Follow-ups in Iteration 9 (Hardening): #38 printed paper, #39 speech (French real voice, mixed language,
  long debriefs).

**Next:** Iteration 3 · Security.
