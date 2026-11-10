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

## Iteration 3 · Security (done Nov 1 2026)
**Done:** security before any feature code. Seven stories, nine pull requests (#51 to #59), CI green on every
merge. Every number below was counted from the repo by a script, not by hand.

| Story | Result |
|---|---|
| #43 Threat model | 60 threats and privacy risks (STRIDE per trust boundary, LINDDUN for privacy, MITRE ATLAS for AI), each with its status and proof; a guard fails any "built" claim that names no real file |
| #44 Security in CI | Dependency audit, CodeQL, Dependabot with a 7-day cooldown, OpenSSF Scorecard (6.6), private vulnerability reporting, a protected main branch |
| #45 Backend | Tokens with the organization only from the token, one database per organization (a cross-organization test for every route), strict input, size and rate limits, security headers, a hash-chained audit log |
| #46 Devices | Phones never hold a token: every request is signed by the phone's Secure Enclave key; one-time enrollment code plus manager approval; replays refused |
| #47 Signed model | OpenSSF Model Signing; the phone refuses a changed, extra or missing file and checks the 633 MB model in 0.37 to 0.59 s, offline; CycloneDX parts lists for the app (model, database libraries) and the backend |
| #48 Prompt injection | 30 attacks through the real offline path on the phone: **6 of 30 fooled the system before the new checks, 0 of 30 after**, 0 false alarms |
| #49 Lost, seized or forced | ADR 0012: least data, mission keys on a 14-day lease, a signed shred order for revoked phones, no hidden wipe, an app lock that guards the data key; a one-page data handling sheet; all 24 OWASP MASVS v2.1 controls with honest status |

**Measured:**
- Tests: 423 (backend 164, scripts 92, main app 32, encryption lab 50, document lab 62, speech lab 23).
- Threat model: 19 built, 12 spike, 24 planned, 5 accepted. MASVS: 4 built, 5 spike, 8 planned, 5 accepted,
  2 not applicable. Self-assessed, **not independently audited**.
- Mutation checks (a rule broken on purpose must fail a test): 102 counted in #47 to #49, all caught after
  the survivors got their own tests; #43 to #46 were checked rule by rule without a count.

**Learned:**
- **The real phone finds what the simulator cannot.** The model check refused the real model on the iPhone
  (a `/private` path bug, it failed safe), and the first injection run crashed on MLX memory. Both were
  fixed with a test and run again on the phone.
- **The model is not the defense.** It obeyed 3 of 30 tricks and wrote negative numbers when one sentence
  was added to a debrief. Forged documents fool any reader; only the bank's own records catch them.
- **Test the scorer too.** The first phone run showed two flaws in our own scoring (garbage counted as
  "resisted", "$48,000" not matched to "forty eight thousand"). Fixed test-first before the final run.
- **Research before building changed four plans:** an official model-signing standard existed, so we used
  it; a hidden duress wipe can get staff prosecuted, so there is none; a Face ID yes/no can be bypassed, so
  the lock guards the key; one phone session can be scored before and after, so it was.
- **Guards keep documents honest.** The threat model, MASVS matrix, data handling sheet, parts lists and ADRs
  are each checked on every commit, so a claim cannot drift from the code. A surviving mutation was the best
  review every time: it named a missing test.

**Changed in the plan:**
- #47 uses OpenSSF Model Signing instead of a home-made hash list; #48 scores one phone session twice and
  added three checks found while designing the attacks (a label printed twice, the bank's payment record,
  the invoice's own row) and one found on the phone (impossible values).
- #49: no duress PIN; the shred order covers all missions until the backend has a mission store (Phase 5);
  the MASVS matrix allows "accepted" with a reason, like the threat model.
- Spike code (encrypted store, key lease, shreds, checks) is rebuilt test-first in the app from Phase 4.

**Open** (each is an issue in its iteration, so nothing lives only here): the phone side of the shred order
(#60), minimum iOS 26 (#61), a time limit for the model (#62), the no-tools test T08 (#63), an advisory scan
for Swift packages (#64), adaptive injection attacks (#65), and an independent security review (#66).

**Next:** Iteration 4 · Evidence store, expanded with research before building, like this one.

## Iteration 4 · Evidence store (done Nov 2 2026)
**Done:** the spike code became the app's own store, built test-first, then run on the real iPhone. Nine
stories, eight pull requests (#76 to #83) plus this review, CI green on every merge.

| Story | Result |
|---|---|
| #68 Foundations | Minimum iOS 26 (closes #61), every file the app creates is Complete, SQLCipher in the app through our GRDB 7.12.0 fork, a test that no part of the app links Apple's plain SQLite |
| #69 Encrypted store | One database key per user in the Keychain, this phone only, behind Face ID or passcode; a per-user folder kept out of backups; the store pauses when the phone locks |
| #70 Mission keys | One key per mission wrapped by a Secure Enclave key, notes sealed with it, a 14-day lease, every shred recorded |
| #71 Signed evidence v2 | The signature also covers kind, clock source and location; the app and the server agree byte for byte |
| #72 Lineage | Every fact and sentence traces back to its evidence; records cannot be changed; a hash-chained audit log |
| #73 App lock | Face ID with one prompt, a privacy cover in the app switcher, locks again after 2 minutes away |
| #62 Model time limit | Every model call stops after 20 s; a stopped answer is never used |
| #74 Store proof | The whole store on the iPhone: 9 of 9 checks, lock test 4 of 4, the phone's signed chain verified by the server's Python code ([store proof](../store-proof.md)) |
| #75 This review | Threat model and MASVS statuses moved to built only where the app and the phone prove it; a guard that stops stale plans |

**Measured:**
- Tests: 669 (backend 202, scripts 116, main app 216, encryption lab 50, document lab 62, speech lab 23),
  up from 423.
- Threat model: 27 built, 6 spike, 22 planned, 5 accepted (was 19, 12, 24, 5). MASVS: 10 built, 2 spike,
  5 planned, 5 accepted, 2 not applicable (was 4, 5, 8, 5, 2). Self-assessed, **not independently audited**.
- Mutation checks: 149 counted in #69 to #72, #62, #74 and #75, all caught or shown to be equivalent; #68
  and #73 were checked step by step without a count. OpenSSF Scorecard 6.6.

**Learned:**
- **The real phone found two bugs that every simulator test missed.** Chip keys never worked on a phone:
  the Keychain item that holds a Secure Enclave key's blob was saved with a rule only the chip key can use
  (error -25293), so mission keys and signing failed on the iPhone while all tests passed. And a read while
  the phone was locked crashed the app (SIGBUS): the pause stopped writes only, but a read still touches the
  database's index file, which iOS had locked. Both were fixed test-first and the phone run passed after.
- **Run the whole test suite on the phone, not only the new tests.** It also showed a test flake (a fake
  lock in one test paused another suite's store, because the signal is app-wide) and tests that needed
  files only the Mac has. Both fixed at the cause, not skipped.
- **A failed phone run can be the user's step, not the code.** The first lock test recorded no lock at
  all; the results file showed it, so we read the data before changing any code.
- **Statuses drift quietly.** Four rows still pointed at Phase 4 for work that was never part of it. A new
  guard rule now fails any plan that names a finished phase, and the MASVS count is checked against the rows.

**Changed in the plan:**
- Every read goes through one door that pauses with the writes; the database pool is private, so nothing
  can skip it.
- The model time limit (#62) moved into this iteration; the phone side of the shred order stays in
  Phase 8 (#60).
- T02, T03 and T05 now point to Phase 6, MASVS-PRIVACY-3 to Phase 9.

**Open** (each is an issue): a store proof in a Release build (#84), a lock test over hours with the app
ended by iOS (#85), plus the open items from Iteration 3 (#60, #63 to #66).

**Next:** Iteration 5 · Mission pack: the backend prepares a mission, the phone downloads it and works
offline.

## Iteration 5 · Mission pack (done Nov 5 2026)
**Done:** the backend prepares a signed mission pack, the phone downloads it, keeps it encrypted and works
offline, all on a real server and proven on the real iPhone. Twelve stories, 22 pull requests (#96 to #120)
plus this review, CI green on every merge.

| Story | Result |
|---|---|
| #87 Field Navy theme | One theme file (light, dark, increased contrast, 4.5:1 checked), Dynamic Type only, the logo as app icon and on the lock and launch screens; guards against raw colors and fixed sizes |
| #88 One database per organization | Postgres, one database and two roles per organization; one organization's login cannot reach another's database; a shared directory holds ids only |
| #89 Signed mission pack | P-256 over the exact manifest bytes, every file by SHA-256 and size, a never-older version rule, limits in the contract |
| #90 Signed requests and shred orders | The phone signs every request with its chip key and a request counter; a revoked phone gets a signed shred order |
| #60 Shred order on the phone | Verified against the pinned key, then the missions destroyed and the shred recorded |
| #91 Download that survives a bad signal | 1 MiB pieces with resume, pauses for no connection, a busy server and the phone lock, never fails for them |
| #92 Ready for offline | The pack checked again and sealed into the encrypted store in one transaction; the mission list and pack screens |
| #93 Site checklist | The KoBo / XLSForm format, a contract with limits, English and French, an .xlsx converter on the server |
| #103, #104 The real server | Staging and production on a shared server (ADR 0013): containers by digest, backups with a tested restore, TLS 1.2+; Debug, Staging and Release builds each talk only to their own server |
| #94 iPhone proof | 10 of 10 steps on the iPhone against staging: Wi-Fi, mobile data, IPv6 only, airplane mode, the lock, a server restart, a wrong clock, an old app, a revoke ([pack proof](../pack-proof.md)) |
| #95 This review | T32 to built, Phase 5 finished in the guard, the security docs and README brought up to date |

**Measured:**
- Tests: 1,903 (backend 864, scripts 340, main app 564, encryption lab 50, document lab 62, speech lab 23),
  up from 669.
- Threat model: 46 built, 5 spike, 15 planned, 5 accepted (was 27, 6, 22, 5), plus 7 privacy risks. MASVS:
  12 built, 2 spike, 3 planned, 5 accepted, 2 not applicable (was 10, 2, 5, 5, 2). Self-assessed, **not
  independently audited**.
- Mutation checks: 744 counted in the stories' pull requests, all caught or shown to be equivalent; #92 and
  the earlier #94 fixes were checked rule by rule without a count. OpenSSF Scorecard 6.9 (was 6.6).

**Learned:**
- **The real phone found 11 bugs the simulator and the local end to end hid.** Among them: a crash because
  the system calls the background task's handler off the main actor; file paths broken by the space in
  "Application Support"; a wrong clock that made the phone refuse its own genuine shred order (security);
  a shredded phone that could never connect again. Each was fixed test first ([pack proof](../pack-proof.md)).
- **A store rule that looked safe blocked a normal case.** One shred per mission ever meant a mission sent
  again after a shred could never be destroyed again. The fix needed design first: mission lives (ADR 0008).
- **CI only runs when there is a pull request.** An iOS 27-only call built on the Mac and broke on CI's
  Xcode 26, found a day late because the branch had no PR yet.
- **A mutation run can lie through Python's cache.** A mutant restored within the same second and the same
  size left a stale compiled file, and the next test run used the mutant. Mutation runs now turn the cache off.
- **Statuses drift outside the guarded files too.** The README still said Iteration 2 and the review page
  counted 67 threats; both fixed here.

**Changed in the plan:**
- The backend moved to a real shared server in this iteration (#103, ADR 0013) instead of staying local, so
  the phone proof ran against staging, not a laptop.
- A pull request is opened as soon as a story branch is pushed, so CI's Xcode builds every push.
- QR code enrollment (#119) added before the demo, in Phase 8; the fictional country Kandor stays until Phase 10.

**Open** (each is an issue): the manifest asked on every list refresh (#121), a store proof in a Release
build (#84), a lock test over hours (#85), plus the open items from Iteration 3 (#63 to #66) and speech (#39).

**Next:** Iteration 6 · Field flows: document scan, red flags, the voice debrief and the checklist, all
offline on the iPhone.

## Iteration 6 · Field flows (done Nov 8 2026)
**Done:** everything an officer does on a mission works on the phone with no network: the site walk with
photos, red flags by cited rules, document scans turned into checked facts, voice debriefs turned into notes,
and Ask the mission. Fourteen stories, 19 pull requests (#124 to #158) plus this review, all proven on the
iPhone in airplane mode ([field proof](../field-proof.md)).

| Story | Result |
|---|---|
| #123 Logo and airplane | Home screen lockup and a diagonal app icon |
| #125 Workspace and Before you go | The mission's workspace; one check before leaving (pack, the model's self-test, speech files, space); the model inside the app |
| #127 Fast and safe CI | Half the wait, the same tests |
| #129 Site walk | Agreed actions and the checklist offline, photos as signed evidence with their place |
| #134 Red flags | Cited rules on the mission's numbers, stored at the walk's end and never changed |
| #136 The model in the app | Verified, constrained to a grammar, time-limited, no tools |
| #138 Scan to facts | Pages read on the phone, every fact grounded on its page and cross-checked, confirmed by the officer |
| #142 Voice debrief | Consent, recording kept as signed evidence, text on the phone, every spoken number read back |
| #145 Ask the mission | Answers from the mission's records with their sources; code writes the answers, the model only chooses |
| #151 A correction must come from the page | The value the check rejected is refused; typed values checked on the pages; the page's values one tap away |
| #152 Debrief notes by code | Each sentence labelled by cue words, a note is its sentence word for word; no model |
| #153 Names and accents | The dictation engine with the mission's names, unsure words underlined, "Condor -> Kandor?" |
| #154 Plain words | Statuses and record names in words; "done" says when the bank disagrees |
| #150 Phase 6 proof | The run on the iPhone, the rows and docs, this review |

**Measured:**
- Tests: 2,481 (backend 864, scripts 426, main app 1,056, encryption lab 50, document lab 62, speech lab 23),
  up from 1,903; the main app from 564.
- Threat model: 61 built, 12 planned, 5 accepted (was 46, 5 spike, 15, 5), plus 8 privacy risks (3 built).
  MASVS: 13 built, 1 spike, 3 planned, 5 accepted, 2 not applicable (was 12, 2, 3, 5, 2). Self-assessed,
  **not independently audited**.
- Mutation checks: counted where a pull request states the number, 64 (#126 36, #155 10, #156 6, #157 12),
  every break caught or shown to be dead code and removed; the other stories were checked at every step
  without a count. The Mac probe for #152: the model labelled debrief sentences 15 of 21 at best, code 50 of 51.

**Learned:**
- **Code writes the answers; the model only chooses, or not at all.** On the iPhone the 1.2B model wrote bad
  answers and bad notes (changed quotes, invented a note, a red flag's name taken for its finding). The
  checks held every wrong sentence back, so nothing wrong was saved, but the officer got nothing useful.
  Measured on the Mac, small models choose well and write badly: Ask became code answers plus a chooser,
  debrief notes became code alone (ADR 0005).
- **The iPhone finds what the tests cannot.** Curly apostrophes from the keyboard, a three-second blank
  screen, an invented value typed back as a correction, "Kandor" heard as "Counter", saved notes shown
  nowhere: each found by Lubo on the phone, each fixed test first.
- **A real accent is test data.** One take of Lubo's voice chose the speech engine: fewer word errors and the
  money heard right. Apple's custom names work only with the dictation engine, which our Nov 7 note had missed.
- **Universal beats per mission.** Cue words for notes, a dictionary for names and a sound code for
  suggestions work for any mission and sector; checked on health, school and water sentences.

**Changed in the plan:**
- The model's role shrank on purpose: it chooses an answer line in Ask and does nothing in debrief notes.
- Four stories (#151 to #154) were added from the proof run before Phase 6 closed.
- The demo is a video and the repository, not an install; Phases 8 and 9 stay small so the demo comes sooner.

**Open** (each is an issue): the engine's whitespace that eats real spaces (#159), any sector's words for Ask
(#148), speech with more voices (#39), the agreed actions in French from the pack (#131), plus the open
items from Iterations 3 and 5.

**Next:** Iteration 7 · Report and approval: a report draft where every sentence links to its facts.

## Iteration 7 · Report and approval (done Nov 9 2026)
**Done:** the aide-memoire is written by code from the mission's records, every sentence citing its facts and
each fact its signed evidence; the officer removes, adds or edits sentences, each checked against the facts
picked; a saved draft is approved with Face ID and signed by the phone's Secure Enclave, then locked. Four
stories, 3 pull requests (#165 to #167) plus this review, proven on the iPhone in airplane mode
([field proof](../field-proof.md#field-proof-phase-7-on-the-iphone-164)).

| Story | Result |
|---|---|
| #162 Report sources | The pack (with the server's signature) and the finished walk become signed evidence; pack records, walk answers and raised flags become facts; deployed to staging and production by the server session |
| #161 Report drafted by code | Five aide-memoire sections, every sentence proven; "No proof" with the reason for the officer's own words; drafts append-only; short (one sentence per invoice, no repeats) and in plain words |
| #163 Approve with Face ID | A separate Secure Enclave key that asks every time; one signature over the saved draft's exact bytes; locked after; opens with a spinner |
| #164 Phase 7 proof | The run on the iPhone, the rows, this review |

**Measured:**
- Tests: 2,554 (backend 868, scripts 430, main app 1,121, encryption lab 50, document lab 62, speech lab 23),
  up from 2,481; the main app from 1,056.
- Threat model: 65 built, 10 planned, 5 accepted (was 61, 12, 5), plus 8 privacy risks (3 built, 4 planned,
  1 accepted). MASVS: 14 built, 1 spike, 2 planned, 5 accepted, 2 not applicable (was 13, 1, 3, 5, 2).
  Self-assessed, **not independently audited**.
- Mutation checks counted from step 7.2.7 on: 44, every break caught (two survivors at first, each closed by
  a new test).

**Learned:**
- **A test mission is not a real one.** The 77 sentences were mostly Phase 6's test data (three scans, many
  debriefs); the rules that made it short (one sentence per invoice, no repeats) are right anyway, and a clean
  mission gives 14. Record the demo on a clean mission.
- **Sign what was saved, not what is on screen.** Approve is on only when the screen holds exactly the saved
  draft, and the store refuses a signature over any other bytes.
- **One prompt per approval.** A fresh context with no reuse, and the signature itself asks (no second
  `evaluatePolicy`), after reports of two signatures racing the Face ID prompt since iOS 26.1.
- **Every slow screen gets a spinner.** The report froze the way Ask once did; the same fix (work off the main
  thread) is now the rule.

**Open:** #168 Face ID again before destroying a mission; #169 the cancel on the iPhone in the Phase 9 run;
#148 the pack brings its own words (now also the walk's French titles and the invoice's field names).
**Next:** Iteration 8, sync and the manager dashboard.

## Iteration 8 · Sync and dashboard (done Nov 10 2026)
**Done:** the approved report leaves the phone and the server checks every signature before it keeps
anything; managers sign in with a passkey and review it on a dashboard in the bank's own reading order (the
portfolio, the project, the aide-memoire with every sentence's proof, the audit trail); they endorse it with
Touch ID or send it back with a note, and the officer answers with version 2. Eleven stories (#171 to #180,
#193), PRs #181 to #196, proven end to end on production
([field proof](../field-proof.md#field-proof-phase-8-on-production-180)).

| Story | Result |
|---|---|
| #171 Approval keys | The phone's Face ID approval key kept by the server per phone, append-only |
| #172 Sync | One batch, every check first (chain, no rollback, the approval over exactly these sentences, lineage), stored in one transaction, idempotent |
| #173 Send | Only an approved report, once, with one key; the review says exactly what goes; waits offline and goes by itself |
| #174 Passkey sign-in | Touch ID on the Mac, one-time invites, `__Host-` session, Origin check on every POST, the dashboard's own content policy |
| #175 to #177 Dashboard | Portfolio (risk radar), project page, report page (proof drawer, verified badge re-checked on every load, red flags only for the `confidential` role, print view) |
| #178 Endorse, send back, trail | Endorse with the manager's own passkey over a challenge naming the report version; send back with a note; versions; separation of duties in Postgres; "Chain intact" only when the log verifies |
| #179 Deploy | Staging, then production, by image digest, backup first, by the server session |
| #193 The phone's side | The decision read on the next contact; version 2; the walk photo sent; the phone named |
| #180 Phase 8 proof | The run on production, the rows, this review |

**Measured:**
- Tests: 2,799 (backend 1,082, scripts 430, main app 1,152, encryption lab 50, document lab 62, speech lab
  23), up from 2,554; the backend from 868.
- Threat model: 76 built, 2 planned, 5 accepted (was 65, 10, 5), plus 8 privacy risks (4 built, 3 planned, 1
  accepted). MASVS unchanged: 14 built, 1 spike, 2 planned, 5 accepted, 2 not applicable. Self-assessed,
  **not independently audited**.
- Mutation checks on every story; each survivor closed by a new test or by removing dead code.

**Learned:**
- **Staging first catches what tests cannot.** The blocked recordings, the wrong passkey offered and the raw
  values were all found by clicking the real pages, not by the suites.
- **Know which server a phone talks to.** The production app had never been enrolled; the run started with
  a one-time code. Check the enrollment before any demo.
- **Stacked pull requests need care at merge.** Deleting a merged base closed the next one, and keeping "our"
  side in merges brought back two old copies of functions; after each merge, compare the tree with the reviewed
  code and run the full suites.
- **Seed demo data without touching the phone's mission.** A republished pack would have shown "a newer pack"
  on the officer's report; the extra projects are published once, never the roads pack.

**Open:** #169 the Face ID cancel on the phone (Phase 10 recording); #184 422 before the device check; the
retention clock, purge after sync and encryption of backups (Phase 9); the sample point shows a real location
in a recording (use a test location for the video).
**Next:** Iteration 9 hardening, then Iteration 10, the demo recorded on production on a fresh mission, with
Ask the mission shown offline.
