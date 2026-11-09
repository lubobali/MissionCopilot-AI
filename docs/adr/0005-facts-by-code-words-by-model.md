# ADR 0005: Facts by code, words by the model

- Status: accepted
- Date: 2026-10-30

## Context
In the bake-off, every model invented or misread numbers or dates at least once, and none found the
key risk (85% of the contract paid while only 50% of the road was built). A supervision report with a
wrong number is worse than no report.

## Options
1. Trust the model, ask a person to double-check every number.
2. A bigger model: slower on the phone, and the 3B model still invented dates.
3. Split the work: **code** extracts numbers, does all arithmetic and runs the risk rules; the **model**
   only writes sentences from facts code has already verified, using constrained (grammar or JSON schema)
   output.

## Decision
Option 3.

## Why
- Arithmetic and comparisons are exact in code and wrong too often in small models.
- Constrained output makes the model's answer machine-checkable: every sentence must reference fact ids.
- Every fact keeps its source page and the rule that produced it, which supports ADR 0009 (provenance).

## Consequences
- Extraction rules must be written and tested for each document type (invoice, progress report).
- The model gets less freedom; reports read slightly more formal.
- Iteration 2 must prove constrained output works on the phone.

## Evidence (spikes #12 and #13, on an iPhone 13 Pro Max, offline)
- Free text, both engines: numbers wrong (8.5M written as 85,000,000), risk never found.
- Constrained extraction (JSON Schema grammar) + code checks: **20/20 valid, 20/20 all fields correct, MC-01
  raised 20/20**, 3.1 s each, deterministic. Free-text JSON on the same task: 0/20 valid.
- A whitespace bias is required: without it the greedy loop looped on tabs (docs/spikes/02-structured-output.md).

## Evidence (spike #15: scanned documents to facts, offline)
- Scan -> constrained extraction -> 8 facts -> MC-01: 8/8 correct on clean pages and on screen photos,
  about 5 s, in airplane mode (docs/spikes/05-documents.md).
- In the dark the model returned two wrong numbers (0 km of 0 km). **Grounding**, a code check that every
  value appears in the scanned text, flagged both for review; MC-01 refused to compute. Zero wrong values
  were presented as checked.
- **Added rule:** every extracted fact must be grounded in its source document by code. An ungrounded fact
  is "needs review" and cannot be used in a report until a person confirms it.

## Evidence (spike #14: voice debriefs, offline)
- Both speech engines at times wrote a **wrong number with no warning** ("$85 million" for 8.5 million,
  "$8,500", "km 80" for 18), and Whisper once dropped 30 s of audio while the text still read smoothly
  (docs/spikes/06-speech.md). Grounding cannot catch this: the wrong number is in the transcript.
- **Added rule:** a number from speech is "heard", not evidence. The app reads it back; it becomes evidence
  only after the speaker confirms it, and code cross-checks it against the documents and the other facts.

## Evidence (#145: Ask the mission, on Lubo's iPhone, offline, Nov 8 2026)
- The model writing answers from found sources, even checked sentence by sentence, failed on the basics in
  four iPhone tests: an "answered" switch it set to false 99% of the time, the question written back, "not
  specified" while the total was on screen, a red flag's name taken for its finding. The checks held every
  wrong sentence back, so the officer saw no wrong answer, but saw no answer either.
- Checked on the Mac with the same model and the app's prompts: as a **chooser** (pick the line that
  answers, or none, from lines code wrote; a grammar of the labels) it chose right on every test question,
  and chose none for an off-topic one. Small models choose reliably and write badly
  ([schemas adapted to small models](https://arxiv.org/pdf/2510.07248)); constrained decoding fixes the
  format, not the meaning ([semantic gap](https://arxiv.org/pdf/2609.23742)).
- **Added rule:** answers are written by code. Code answers the questions it knows from the pack's records
  (a payment by invoice number, the total, what is not done, whether something started, with both sides
  when the walk and the bank disagree); for any other question code writes one line from each record
  found and the model only chooses among them. The model never writes an answer.

## Evidence (#151: a correction must come from the page, Nov 8 2026)
- In the Phase 6 proof the model invented three scanned values (1 km, 10000000 km, a finished bridge); code
  locked Confirm, and the same three values were typed back in Correct and saved as the officer's.
- **Added rule:** the officer's correction is checked like the model's value. The value the page check
  rejected is refused; a typed value found on a page keeps its page and position; one not on the pages is
  kept only with a second tap and is cited as "typed by you", never as the page. Code offers the values
  printed on the page; the officer chooses.

## Evidence (#152: debrief notes, Nov 8 2026)
- On the iPhone the model changed the words it quoted, added words never said and invented a note; the checks
  held each one back, but the officer had to fix almost every note.
- Measured on the Mac with the same model, answer keys written first: labelling each sentence decision,
  action, risk or none, the model scored 15 of 21 at best (one pass 10, one at a time 3, calibrated 10,
  yes/no 15) and 9 of 15 on new sentences; code cue words scored 50 of 51, including 15 of 15 from other
  sectors (health, schools, water, energy, social payments), English and French. Code plus the model did worse.
- **Added rule:** debrief notes are written by code, with no model: each sentence that was said is labelled by
  cue words (the officer's spoken label first: "Action", "Risk", "Decision"), and a note is its sentence word
  for word. The officer changes a label, tags a sentence code left, edits or removes. The word lists describe
  how people speak, never a mission's topic; a new language is one more list.

## Evidence (#161: the mission report, Nov 9 2026)
- The report (an aide-memoire: mission, project information, main findings, agreed actions since the last
  mission, next steps, from a real 2025 World Bank aide-memoire) is written by code: each fact becomes one
  sentence in Ask's checked words. Research agrees: rule and template systems make the fewest semantic errors
  in data-to-text, LLM systems add content that is not in the data ([INLG 2024](https://aclanthology.org/2024.inlg-main.47.pdf)).
- Code's own lines hold no number or month their record does not; the officer's added or edited sentences get
  Ask's full check against the facts they pick. A sentence with no proof is shown with its reason and is never
  stored (the store refuses the draft).

## Revisit when
- Never for arithmetic. Revisit the extraction split if document types multiply beyond what rules handle.
