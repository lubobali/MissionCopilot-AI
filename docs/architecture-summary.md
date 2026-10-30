# MissionCopilot-AI: architecture on one page

**Problem.** Field supervision of development and infrastructure projects happens far from reliable
internet, under time pressure, with sensitive information. Reports can drift from what was seen on
site, payments can run ahead of real progress, and knowledge is lost when teams rotate.

**Solution.** Small, offline AI on the iPhone for evidence-first supervision: capture evidence, extract
facts with code, raise cited red flags, and draft the mission report, where **an untraceable claim
cannot be approved** and **nothing leaves the phone before a person approves it.**

## How it works
1. **Prepare (online):** the mission pack (budget, payments, milestones, checklist, last mission's
   promises) is downloaded into an encrypted store.
2. **Field (offline):** photos and scans are signed by the Secure Enclave and hash-chained; code extracts
   facts; versioned rules flag risks live (for example 85% paid vs 50% built).
3. **Report (offline):** a small on-device model writes from verified facts only; every sentence links to
   facts, every fact to evidence.
4. **Approve and sync (online):** approved, signed items upload idempotently to the organization's own
   database; the manager reviews; results export in an OC4IDS shape; the phone crypto-shreds later.

Diagrams: [architecture.md](architecture.md). Data map: [data-classification.md](data-classification.md).
Objects: [domain-model.md](domain-model.md). API: [api/openapi.yaml](api/openapi.yaml).

## Key decisions
| ADR | Decision |
|---|---|
| 0001 | Native iOS app + Python backend (offline AI needs native engines) |
| 0002 | Xcode project defined in a readable file (XcodeGen) |
| 0003 | AI routing by label first, then task: confidential data never reaches cloud AI |
| 0004 | LFM2.5 1.2B on device (about 38 tokens/s on an iPhone 13 Pro Max), Qwen3 1.7B backup |
| 0005 | Code does facts and math; the model only writes, with constrained output |
| 0006 | Offline outbox with an approval gate; idempotent sync |
| 0007 | Integrations behind adapters (checklists real format, document hand-off mock) |
| 0008 | Encrypted store per user, per-mission keys wrapped by the Secure Enclave, crypto-shred; one database per organization |
| 0009 | Lineage modelled on W3C PROV; signed, hash-chained evidence |
| 0010 | Versioned, cited red-flag rules (Open Contracting R067/R068 + custom) |
| 0011 | Export shaped like OC4IDS with risk flags and lineage |

## Quality and delivery
Test-first; CI on every push (secret scan, lint, types, tests, contract and dataset tests, workflow
security lint); iOS tests on a simulator when iOS code changes; Agile in one-day iterations with a
public board, Definition of Done and iteration reviews.

## Status
Iteration 1 (architecture) complete. Next: feasibility spikes on the real iPhone (Iteration 2), then
security, the evidence store, and the user journey.
