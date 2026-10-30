# ADR 0003: AI routing, on-device vs cloud

- Status: accepted
- Date: 2026-10-30

## Context
Field work happens offline, and most mission data is Official Use Only or Strictly Confidential
(see docs/data-classification.md). Some tasks (long documents, photos, charts) are heavier than a
1-2B on-device model handles well.

## Options
1. Everything on-device: private and offline, but weak on heavy tasks.
2. Everything in the cloud: strongest models, but fails offline and sends sensitive data out.
3. Route per task by **data type and label**: on-device by default; cloud only for heavy tasks on
   data labelled Public, after sync.

## Decision
Option 3. A router checks the label first, then the task type.

| Task | Where |
|---|---|
| Notes from a debrief, report wording, questions about the mission | On-device |
| Text and table reading from documents | On-device (Apple Vision), numbers by code |
| Photo or chart understanding | Cloud, only if the item is labelled Public, after sync |
| Anything Official Use Only or Strictly Confidential | On-device only, never cloud |

## Why
- The label check comes first, so a routing bug cannot leak confidential data to the cloud.
- The common field tasks work with no network.
- Same tiered idea as cost-aware LLM gateways: cheap and local first, big model only when needed and allowed.

## Consequences
- Photo and chart understanding is weaker for confidential items (on-device only).
- The router needs tests for every label × task pair.

## Revisit when
- On-device vision models become fast enough on older phones, or a private cloud is available.
