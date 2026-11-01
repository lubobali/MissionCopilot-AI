# Spike #14: offline speech, numbers first

Status: **GO, with changes** (below). An iPhone 13 Pro Max (A15, iOS 27.2) in airplane mode turns a 2-minute
voice debrief into text with two engines. In a quiet room both heard every number in a real non-native
speaker's debrief. Both engines also, at times, wrote a **wrong number with no warning**, so the engine is
not the safety: a spoken number becomes evidence only after a read-back and a code cross-check.
Raw data: results/speech-iphone13promax.json.

## Setup
- **Answer key from the dataset** (`scripts/make_debrief_audio.py`): a fictional field debrief in English and
  French with 11 key facts (km 18, road width 4.9 m vs 7 m spec, 32 of 64 km built, bridge not started,
  invoice 14 for 480,000, paid 8.5 million = 85 percent, planned completion 15 December 2026).
- **Voices:** Mac voices (Samantha English 78 s, Thomas French 84 s); the tester's own voice cloned
  (ElevenLabs), quiet and with road or cafe noise mixed at **exactly 10 dB** by `scripts/mix_noise.py`
  (tested); and the **tester's real voice** into the phone mic, quiet room and loud noise. French real voice
  not tested (no French speaker).
- **Engines:** Apple `SpeechTranscriber` (built into iOS 26+, language files downloaded once) and
  WhisperKit 1.1.1 with `large-v3-v20240930_626MB` (copied to the phone, `download: false`).
- **Scoring by code** (`ios/AILab/SpeechLab`, 23 tests): word error rate (WER) after normalization, and a
  separate **key-facts score**, because WER hides the errors that matter: one wrong number counts as one word.
- **Rule:** wrong-but-confident is the failure; missing-and-flagged is acceptable.

## Results (all offline, recorded by the app as "offline (no network path)")

| WER / key facts of 11 | Apple | Whisper large-v3 |
|---|---|---|
| Mac voice, English | 7.8% / 11* | 6.0% / 11* |
| Mac voice, French | 4.4% / 11 | 4.4-5.3% / 11, but **one run 33% / 9** (see below) |
| Cloned voice, quiet / road 10 dB / cafe 10 dB | 6.0-7.0% / **10** (every round) | 1.4-2.3% / 11 |
| **Real voice, quiet room** | 13.5% / 10 (a word error, numbers right) | **8.8% / 11** |
| Real voice, loud noise | 39% / 6 | 20-38% / 5-10 over 3 runs of the same file |
| Time for 80-110 s of audio | **1.5-2.5 s** | 11-23 s |
| Model in the app | **none** (system files) | 626 MB, about 100 s first load after each install, 1.5-2 s warm |

\* After the scorer fix for "December 15th, 2026" (see below).

## Wrong numbers with no warning
| Engine | Heard | Said | When |
|---|---|---|---|
| Apple | "$85 million" | 8.5 million | cloned voice, all 3 rounds |
| Apple | "kilometer of 80", "December of 2020" | km 18, 2026 | real voice, loud noise |
| Whisper | "$8,500" | 8.5 million | real voice, loud noise, 2 of 3 runs |
| Whisper | about 30 s missing, text still smooth | French debrief | 1 of 5 French runs (1 of 3 with VAD chunking), not repeatable |
| Whisper | invented "Thank you." and a repeated sentence | nothing | real voice, loud noise |

Grounding (spike #15) cannot catch these: the wrong number **is** in the transcript. What catches them:
a read-back the speaker confirms, and code cross-checks against the documents ("$85 million paid" against
85% of a 10 million contract does not add up).

## What else we learned
- **The A15 runs Apple's SpeechTranscriber** (`isAvailable` true; Apple publishes no device list). English
  was already installed; French downloaded in 15 s. The system may remove unused language files, so the app
  must check `AssetInventory.status` before every mission and install while still online.
- **Whisper is not repeatable here:** temperature 0, same file, three different results under noise. When a
  window fails its quality checks, WhisperKit retries up to 5 times, each 0.2 hotter (its defaults), which
  likely explains it. Running with the retries off was not tested.
- **Whisper's first load compiles the model** for the chip (101-105 s), and a new install can repeat it.
- **Noise level matters more than the engine** at the loud end: both fell apart when the noise was within
  9 dB of the voice.
- **Our own mistakes, fixed:**
  - Four scorer gaps where an engine heard the right value in another format ("15 December of 2026",
    "$8500000", "480 thousand", "4.9m"). Fixed test-first and mutation-checked; every rule only makes the
    **same** value match ("85 million" stays different). Logged in the results file.
  - A second recorded take replaced the first; takes now get their own file names.
  - Voice files copied right before an app reinstall were lost; I now list the files on the phone after
    every copy instead of trusting the exit code.
- **Privacy:** the real and cloned voice recordings stay on the phone and the Mac, never in the repo.

## Not tested yet
- French real voice; mixed English and French in one recording; long (10+ minute) recordings; a third
  engine (Parakeet). Tracked for Iteration 9 (Hardening).

## Decision
**GO, with changes for the production build:**
1. **Apple SpeechTranscriber is the default engine:** built in (no model to ship), about 6x faster, same
   result on every run. **WhisperKit stays an option** behind the same interface for accented speakers
   (it was more accurate on the real voice), re-tested in Hardening. ADR 0004 updated.
2. **Spoken numbers are "heard", not evidence.** The app reads every number back; it becomes evidence only
   after the speaker confirms it, and code cross-checks it against the documents. ADR 0005 updated.
3. **Offline readiness check** before a mission: Apple language files installed (`AssetInventory.status`),
   or the Whisper model folder present and loaded once.
4. **Audio is mission data:** encrypted with the mission key (#16), never sent unapproved.
