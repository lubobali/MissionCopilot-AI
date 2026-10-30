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

## Revisit when
- Never for arithmetic. Revisit the extraction split if document types multiply beyond what rules handle.
