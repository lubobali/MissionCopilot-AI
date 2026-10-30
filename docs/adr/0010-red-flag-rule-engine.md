# ADR 0010: Red-flag rule engine

- Status: accepted
- Date: 2026-10-30

## Context
The most costly supervision failures are payments that run ahead of real progress and work that does
not match the specification. Flags must be correct, explainable and reproducible. Small models invented
numbers in testing (ADR 0005), so they cannot raise flags.

## Options
1. Ask the model to spot risks: flexible, but unreliable and unexplainable.
2. Ad hoc checks in code: reliable, but each check undocumented and hard to audit.
3. **A rule engine of versioned, cited rules**: each rule has an id, a source, a formula, a threshold
   and a version; each flag records exactly how it was computed.

## Decision
Option 3. Initial rules:

| Rule id | Source | Raises a flag when |
|---|---|---|
| R068 | Open Contracting red flags guide (2024) | Sum of payments exceeds the contract value |
| R067 | Open Contracting red flags guide (2024) | A milestone is past its due date and not met |
| MC-01 | Custom (payment ahead of progress) | Financial progress minus physical progress is above 20 points (configurable) |
| MC-02 | Custom | The same invoice number or amount appears twice |
| MC-03 | Custom | An invoiced quantity is above the measured quantity |
| MC-04 | Custom | The same photo hash is reused across missions or sites |

Each flag stores: rule id, rule version, the input fact ids, the computed values, the threshold, and
the label inherited from its inputs (integrity flags are Strictly Confidential).

## Why
- Every flag can be reproduced from its inputs and explained in one sentence.
- Citing public rules (Open Contracting) makes flags familiar to procurement and audit teams.
- Thresholds are data, not code, so an organization can tune them without a release.

## Consequences
- Rules only see facts that were extracted; missing documents mean missing flags (shown as "not
  checked", never as "clear").
- Each rule needs unit tests with boundary cases (exactly at the threshold, just above, just below).

## Revisit when
- An organization supplies its own rule set, or more Open Contracting rules become relevant.
