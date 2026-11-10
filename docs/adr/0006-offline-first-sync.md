# ADR 0006: Offline-first sync with an approval gate

- Status: accepted
- Date: 2026-10-30

## Context
Officers work for days with no network. Nothing should leave the phone before a person approves it,
and an upload interrupted halfway must not create duplicates or half-written missions.

## Options
1. Live sync whenever online: simple, but sends unapproved drafts.
2. Peer-to-peer CRDT sync: powerful for teams, but heavy for a first version.
3. Local outbox: only approved, signed items are queued; uploads are idempotent; the server confirms receipt.

## Decision
Option 3. Phone-to-phone team sync is a stretch goal.

## Why
- The outbox is the single gate: if it is not approved, it is not in the outbox, so it cannot leave.
- Idempotent uploads (each item has a stable id and hash) make retries safe on bad connections.
- Server confirmation starts the retention clock for crypto-shredding on the phone (ADR 0008).

## Consequences
- Conflicts are rare by design (one officer owns a mission draft); the rule is: the approved version wins
  and earlier versions stay in the audit log.
- Managers see results only after sync, not live.

## Built (#172, Nov 2026)
The server side as built: one batch per approved report (`POST /v1/missions/{id}/sync`) with the
signed evidence chain and head, the cited facts, the approved draft's sentences and the Face ID
approval. Every check runs before anything is stored (`sync_checks.py`): the chain is the phone's,
unbroken and this mission's; nothing stored is rolled back; the approval is signed by a key the
server keeps for that phone (#171) over exactly these sentences; every sentence has facts and every
fact evidence in this chain. One transaction, append-only tables, the team only (row-level
security). Idempotent by the `Idempotency-Key` and by the approved draft. The files behind evidence
items travel one by one and are kept only when their SHA-256 is the one the phone signed.

## Revisit when
- Several officers need to edit the same mission offline at once.
