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

## Revisit when
- Never for arithmetic. Revisit the extraction split if document types multiply beyond what rules handle.
