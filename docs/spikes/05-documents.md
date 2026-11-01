# Spike #15: document text and tables on device

Status: **GO, with changes** (below). An iPhone 13 Pro Max (A15, iOS 27.2) reads an invoice and a progress
report, tables included, and turns them into the 8 checked facts and the MC-01 flag in about 5 seconds,
offline. When the model got two numbers wrong, code caught both. Raw data: results/documents-iphone13promax.json.

## Setup
- **Test documents** built from the fictional demo dataset by `scripts/make_scan_documents.py`: invoice 14
  (6-row payment table) and the September progress report (milestone table with empty cells), dates printed
  the way people write them. The same script writes **the answer key** (facts, every line, every cell), so
  results are scored by code, never by eye. A test fails if the dataset changes and the documents do not.
- **Reading:** Apple Vision `RecognizeDocumentsRequest` (iOS 26+, on device), VisionKit's document camera.
  Package `ios/AILab/DocumentLab`.
- **Facts:** tables turned into rows, then the spike #13 constrained model (MLX, LFM2.5 1.2B, JSON schema)
  fills 8 facts. **Code** then checks each one:
  - **Grounding:** every value must appear in the scanned text in a printed form, or it is "needs review"
    (ADR 0009: an untraceable claim cannot be approved). Number boundaries ("80,000" is not inside
    "480,000"); the bridge status only from its status line, not from the milestone row
    "Section 3 bridge complete".
  - **Cross-check:** the payment table must add up to "paid to date"; an unreadable amount is reported.
  - **MC-01** computed by code; no result if a total is zero.
- **Rule:** wrong-but-confident is the failure; missing-and-flagged is acceptable.

## Results
Reading (lines found / table cells matched):

| Input | Invoice | Progress report | Time per page |
|---|---|---|---|
| Clean page, Simulator | 9/9, 21/21 | 7/7, 15/15 | (Simulator, not meaningful) |
| Clean page, **A15** | 9/9, 21/21 | 7/7, 15/15 | **0.19 s** warm, 0.7 s cold |
| Photo of a laptop screen | 9/9, 21/21 | 6/7, 15/15 (angled, dim, glare: lost the contractor name) | 0.2-0.4 s |
| Photo of a monitor, dimmed, straight | 9/9, 21/21 | 7/7, 15/15 | 0.4 s |
| Photo of a monitor, dimmed, angled | 9/9, 21/21 | 7/7, 15/15 | 0.7-0.9 s |
| Photo of a monitor, darkest, lights off, angled | 9/9, 21/21 | 7/7, 15/15 | 0.4-0.8 s |

Scan to facts (8 facts, grounding, cross-check, MC-01):

| Input | Correct | Grounded | MC-01 | Wrong but confident | Time |
|---|---|---|---|---|---|
| Clean pages, 3 runs | 8/8 each | 8/8 | raised (85% paid vs 50% built) | none | 0.9 s scan + 4.0 s model |
| Laptop screen photos | 8/8 | 8/8 | raised | none | 0.4 s + 4.0 s |
| **Airplane mode** (recorded: "offline (no network path)") | 8/8 x3 + photos 8/8 | 8/8 | raised | none | 0.8 s + 4.0 s |
| Monitor photos, dimmed, angled | 8/8 | 8/8 | raised | none | 0.8 s + 4.4 s |
| **Monitor photos, darkest** | **6/8** (km built 0 of 0) | **6/8: both wrong values flagged** | **cannot compute** | **none** | 0.6 s + 4.1 s |

Model load 0.6-0.75 s. Thermal state stayed nominal in every run.

## The failure that proves the design
In the darkest round the scanner missed the page edges and captured the whole monitor (browser tabs and
other windows). Vision still read the report perfectly ("Road built: 32 of 64 km"), but the model, given that
extra text, returned `kmCompleted: 0, kmTotal: 0`. Grounding found no "0 km" in the scan and flagged both
values for review, and MC-01 refused to divide by zero instead of raising or hiding a flag. No wrong value was
presented as checked.

## What else we learned
- **The A15 runs `RecognizeDocumentsRequest`** (Apple publishes no device list), and it runs in the Simulator.
- **Apple's iOS 27 OCR tool for Foundation Models needs Apple Intelligence**, which this phone lacks; it
  confirms bundling our own model (ADR 0004).
- **CI drift:** the iOS job built with Xcode 16.4 (macos-15 default) while development used Xcode 27.2. CI now
  runs on macos-26 with Xcode 26.6 pinned by path (the newest GitHub offers).
- **A free-Apple-ID app must be verified online once after each install** before it opens offline.
- **Our own mistakes, fixed:** a scan scored against the wrong page (page is now detected by code); only the
  first page of a multi-page scan was read; "newest photo" sorted by file name, so two facts runs used older
  photos. Those two results were discarded and each run now records the photos it used.
- **Privacy:** photos of a whole screen can capture unrelated personal content. Scan photos stay on the phone
  and out of the repo; a real-paper mode records counts only.

## Not tested yet
- **Printed paper** (texture, curl, shadows): no printer at hand. Tracked in #38 (Iteration 9, Hardening).

## Decision
**GO, with changes for the production build:**
1. **Grounding is required** for every extracted fact (ADR 0005 updated). Ungrounded means "needs review".
2. **Bad-crop warning:** if the scan contains text outside the detected page, ask for a retake.
3. **Second opinion by code** for facts with a fixed printed pattern ("32 of 64 km", "USD 480,000"), compared
   with the model's value.
4. **Real paper** test in Phase 9 (#38).
5. Prompt injection from scanned pages goes into the Phase 3 threat model.
