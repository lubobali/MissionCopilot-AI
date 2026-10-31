# Spike #17: signed, hash-chained evidence

Status: **GO**. Every photo and scan can be signed by the iPhone's Secure Enclave and chained so tampering
is detected offline, and the Python backend verifies the phone's chain with only the public key.
iPhone 13 Pro Max, iOS 27.2. Raw data: results/evidence-iphone13promax.json (phone) and
results/evidence-chain-iphone13promax.json (the exported chain, used as a Python test fixture).

## Setup
- **One Secure Enclave P-256 signing key per user**, created "when unlocked, this device only" (one shared
  setting with the mission key vault of spike #16). Its blob lives in the Keychain.
- **Each item signs** `{capturedAt, fileSHA256, missionId, prevHash, seq}` as sorted-key JSON (ISO 8601 UTC,
  integers only). The exact signed bytes and a DER signature are stored.
- **Link:** `prevHash` = SHA-256(previous signed bytes ‖ previous signature); the first item links to 64 zeros.
- **Signed head:** `{count, headHash, missionId}`, re-signed after every item, so a cut-off last item shows.
- **Verifiers never rebuild the JSON.** They check the stored bytes, so Swift and Python cannot disagree on
  formatting. Code: `EvidenceChain` (Swift, EncryptionLab package) and `missioncopilot_backend.evidence`.

## Results
| Check | Swift (phone) | Python (backend) |
|---|---|---|
| Chain of 3 + head, public key only | ✅ valid | ✅ valid (the phone's own chain) |
| One byte changed in item 2 | ❌ item 2: bad signature | ❌ item 2: bad signature |
| Last item cut off | ❌ head: count mismatch | ❌ head: count mismatch |
| Middle item removed / items swapped | ❌ caught (Simulator tests) | ❌ removed middle caught |
| Another key | ❌ item 1: bad signature | ❌ item 1: bad signature |
| Speed on the phone | chip signs in **20 ms** per item; verify 2-13 ms | |

Tests: 17 in Swift (8 chain, 6 head, 3 chip signer on the hosted suite) and 8 in the backend.

## What the mutation checks found
- **The sequence check was untested:** removing it passed every test, because the hash link always fires
  first. Added a direct test with a correctly linked but wrongly numbered item.
- **Cross-language data catches format drift:** changing the link formula on one side passes all
  same-language tests (both sides change together), but fails the Python test, because the phone's real
  chain pins the format.

## Known limit (pinned by a test on purpose)
On the phone alone, an **older** signed head with the chain cut back to match it still verifies. Only an
outside record of the latest head can catch that rollback: the server's sync receipt (ADR 0006, Phase 8).
A test asserts this limit so nobody claims more than was built.

## Decision
- **GO on ADR 0009** as written, plus the signed head and the exact-bytes rule (ADR updated).
- Phase 4 rebuilds the chain test-first in the main app's evidence store; Phase 8 adds the server receipt
  that anchors the head.
