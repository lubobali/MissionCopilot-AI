# ADR 0009: Evidence provenance and signing

- Status: accepted (signing feasibility proven in Iteration 2)
- Date: 2026-10-30

## Context
Supervision reports can drift from what was seen on site, and a document or photo can be altered after
the fact. Every claim in a report must be traceable to evidence, and evidence must be tamper-evident,
even offline.

## Options
1. Store evidence files with timestamps only: easy, but nothing proves they were not changed.
2. Content credentials (C2PA) on every photo: a strong standard, but the official mobile libraries are
   still early.
3. **Own lineage model plus device signing**: lineage modelled on W3C PROV, every evidence item hashed,
   chained to the previous item, and signed by a Secure Enclave key. C2PA added later as a stretch goal.

## Decision
Option 3.

### Lineage (modelled on W3C PROV)
- **Entity:** a page, a photo, a debrief segment, a fact, a flag, a report sentence.
- **Activity:** an extraction (which rule and version), a draft, an approval.
- **Agent:** the device (software) or a person (approver).
- Every **fact** links to its source entity (page and region, photo, or debrief time range) and to the
  rule version that produced it. Every **report sentence** links to one or more facts.

### Signing and chaining
- Each evidence item stores: content hash (SHA-256), the previous item's hash, capture time, location
  if allowed, and a signature by a Secure Enclave P-256 signing key over all of it.
- Changing one byte of any item, or removing one, breaks the chain and is detected, offline.

### Approval gate
- **An untraceable claim cannot be approved:** a report sentence with no linked fact, or a fact with no
  linked evidence, blocks approval and is shown to the officer.

## Why
- Turns "trust me" into "check it": any reader can follow a sentence back to the evidence.
- Works with no network; verification needs only the public key.
- Uses hardware keys that cannot be copied off the phone.

## Consequences
- Device clocks can be wrong: capture time is recorded with the clock source and treated as a claim,
  not proof. The hash chain still proves order.
- Lineage adds storage and code to every feature, which is why it is built first (Iteration 4).
- Not a standard format for outside tools until C2PA is added.

## Revisit when
- Official C2PA mobile libraries become stable, or a partner requires content credentials.
