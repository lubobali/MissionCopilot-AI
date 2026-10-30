# ADR 0007: Integrations behind adapters

- Status: accepted
- Date: 2026-10-30

## Context
Organizations already use field data tools (KoBoToolbox / XLSForm checklists are common) and document
systems. A demo cannot connect to private internal systems, but the design must show where they plug in.

## Options
1. Hard-code each integration inside the app logic.
2. Build no integrations.
3. Adapters: the core talks to small interfaces; each external system is one adapter that can be real or mock.

## Decision
Option 3.

| Adapter | Status |
|---|---|
| Field checklists (KoBo / XLSForm format) | Real format: checklists import into the mission pack |
| Document hand-off (SharePoint style) | Mock: approved reports go to a stand-in endpoint |
| Cloud AI | Real (NVIDIA NIM), behind the routing rules of ADR 0003 |

## Why
- A real system can replace a mock without touching the core or its tests.
- Tests run against mocks for external systems and real code for everything internal.
- It shows how the tool fits existing systems instead of replacing them.

## Consequences
- One extra layer to maintain per integration.
- Mocks must be clearly labelled so nobody mistakes them for real connections.

## Revisit when
- A real organization provides a document system or identity provider to connect.
