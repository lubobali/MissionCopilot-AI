# Signed evidence format (payload v2)

Every photo, scanned page or recording is recorded as one **signed record**: the exact bytes the phone's
Secure Enclave signed (the payload) and the signature over them (ADR 0009). Verifiers check those bytes
**as stored** and never rebuild the JSON, so the phone (Swift) and the server (Python) always agree. The
API contract carries the same rules (`EvidencePayload`, `Evidence`, `ChainHead` in
[api/openapi.yaml](api/openapi.yaml)); a test fails if this page and the contract disagree.

## Encoding
- UTF-8 JSON, **keys sorted** at every level, no spaces, slashes not escaped.
- **Integers only**, no decimals: Swift and Python can print the same decimal differently, which would
  change the signed bytes.
- `capturedAt` in UTC, whole seconds: `2026-11-12T09:41:07Z`.
- Signature: ECDSA P-256 over SHA-256 of the payload bytes, DER, base64 in the API.

## Fields

| Field | Type | Rule |
|---|---|---|
| `v` | integer | Always `2` (the spike's chain is version 1, below) |
| `seq` | integer | 1 for the first item of a mission, then +1, no gaps |
| `prevHash` | hex, 64 | The previous item's link; 64 zeros for the first item |
| `contentHash` | hex, 64 | SHA-256 of the file (photo, page image, audio) as captured |
| `kind` | text | `photo`, `scan`, `audio`, `pack` (the mission pack: its manifest bytes and the server's signature, #162) or `walk` (the finished site walk as canonical JSON, #162) |
| `capturedAt` | text | When the item was captured, UTC, whole seconds; a claim, see `clockSource` |
| `clockSource` | text | Where that time came from: `device` (phone clock) or `gnss` (satellite time) |
| `location` | object | Optional: `latE6` and `lonE6`, whole micro-degrees; absent when location is not allowed |
| `missionId` | text | The mission this evidence belongs to |

## Example

```json
{"capturedAt":"2026-11-12T09:41:07Z","clockSource":"device","contentHash":"cdff23fe43f30e4accf43fdcc2df748deaa7b44e6395529d08b2ce01927547d7","kind":"photo","location":{"latE6":12345678,"lonE6":-23456789},"missionId":"kandor-roads","prevHash":"0000000000000000000000000000000000000000000000000000000000000000","seq":1,"v":2}
```

## Chain and head
- **Link** of an item = SHA-256 of its payload bytes followed by its signature bytes, as hex. The next
  item's `prevHash` must equal it, so changing or removing any item breaks the chain.
- **Signed head**, re-signed after every item: `{"count":N,"headHash":"<last link>","missionId":"..."}`
  (same encoding, signed the same way). It catches a cut-off last item. An older head with the chain cut
  back to it still verifies; only the server's record of the latest head catches that (ADR 0006).

## Version 1
The chain signed by the iPhone in spike #17 is version 1: `{capturedAt, fileSHA256, missionId, prevHash,
seq}`, without kind, clock source or location. Verifiers still accept it, so that proof stays checkable;
new evidence is always version 2.
