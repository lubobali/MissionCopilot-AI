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
- Built in #134 (Nov 6, 2026):
  - The rules are data in `docs/rules/red-flag-rules.json` (id, version, source, English and French
    title, threshold), bundled into the app as that very file; `scripts/check_red_flag_rules.py` keeps
    it on this table's ids, sources and order. Every rule flags when its value is strictly above the
    threshold.
  - Today the file ships inside the signed app, so changing a threshold still needs a new build. Tuning
    without a release (the Why above) needs the rules to come signed in the pack: not built yet.
  - Each rule ends as flag, clear or not checked with its reason; a rule the app has no code for is not
    checked, never dropped. MC-03 is not checked until the document scan gives invoiced and measured
    quantities (6.5).
  - MC-04 compares the signed SHA-256 of the photo's bytes, so it catches exact copies only, on this
    phone only; other phones after sync (Phase 8). A shredded mission cannot be read and is counted.
  - Flags are live while the site walk is open and stored at its finish, sealed, Strictly
    Confidential and append-only; the audit log names the raised rule, never a value.

## Revisit when
- An organization supplies its own rule set, or more Open Contracting rules become relevant.
