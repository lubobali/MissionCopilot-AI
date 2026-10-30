# ADR 0011: Standards-shaped export

- Status: accepted
- Date: 2026-10-30

## Context
Approved mission results should be usable by other tools (dashboards, audit, transparency programs)
without custom integration. Infrastructure transparency already has an open standard that tracks
physical progress next to financial progress.

## Options
1. Our own JSON format: simplest, but every consumer needs custom work.
2. A fully certified implementation of a standard: most interoperable, but too large for this scope.
3. **Export shaped like the Open Contracting for Infrastructure Data Standard (OC4IDS)**, with a small
   extension for risk flags and lineage.

## Decision
Option 3. The approved mission exports as JSON that follows OC4IDS field names where they exist:

| Our data | OC4IDS field |
|---|---|
| Physical progress (km or %) | `metrics` with id `physicalProgress` |
| Financial progress (% paid) | `metrics` with id `financialProgress` |
| Payments | `contractingProcesses[].summary.transactions` |
| Milestones | `milestones` (dueDate, dateMet, status) |
| Source documents with pages | `documents` (pageStart, pageEnd) |
| Risk flags | extension `riskFlags[]` (rule id, version, inputs, values, threshold) |
| Lineage | extension `lineage` (sentence → facts → evidence) |

## Why
- The standard already has the exact comparison this project cares about: physical vs financial progress.
- Field names familiar to transparency and audit teams lower the cost of using the data.
- Extensions keep our extra value (flags, lineage) without breaking the standard shape.

## Consequences
- "Shaped like" is not "certified": the export is validated against our own JSON Schema subset in CI,
  not against the full standard.
- Only Public or explicitly cleared data may be exported outside the organization (labels, ADR 0008).

## Revisit when
- A consumer needs full OC4IDS compliance, or another standard (for example IATI) is required.
