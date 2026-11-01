# On-device model: provenance and signature

The model the app runs is signed with **OpenSSF Model Signing** (`model-signing` 1.1.1, sigstore), and
the app refuses a model folder whose signature does not verify (threat model T46).

| | |
|---|---|
| Model | `mlx-community/LFM2.5-1.2B-Instruct-4bit`, revision `dee2f8a2786e` (spike #12) |
| Weights | `model.safetensors`, SHA-256 `d837f243744bbdbe7dd032f90b482a1c45d5b6035b25c1d7804d0f4c74b5c004` |
| Files signed | the 9 files the app loads (weights, index, config, generation config, tokenizer, tokenizer config, special tokens, chat template, README) |
| License | LFM Open License v1.0 (may need a commercial agreement for large organizations; ADR 0004) |
| Bundle | [`LFM2.5-1.2B-Instruct-4bit.sig`](LFM2.5-1.2B-Instruct-4bit.sig): a sigstore bundle, DSSE envelope over an in-toto statement with every file's SHA-256 |
| Public key | [`model-signing.pub.pem`](model-signing.pub.pem) (P-256); the private key is never in the repo |

## Verify it yourself
Download the model at that revision, then:
```
python3 scripts/sign_model.py verify <model folder> docs/models/model-signing.pub.pem docs/models/LFM2.5-1.2B-Instruct-4bit.sig
```
This runs the official tool, pinned. A changed byte answers "Hash mismatch"; an extra file answers
"Extra files found".

## On the iPhone
Measured on an iPhone 13 Pro Max in airplane mode ([results](../spikes/results/model-signature-iphone13promax.json)):
all 9 files verified in **0.59 s** on the first run and **0.37 s** on the next two, with no change in free memory.
The check hashes the weights in 4 MB pieces, so the 633 MB model never sits in memory at once.

The real phone found a bug the simulator could not: iOS app folders live under `/private/var`, and one step
dropped `/private` while another kept it, so every file name came out cut short. The check **refused** the good
model (it failed safe, never the other way). A test now copies the model under `/private/tmp` to keep it fixed.

## Parts list
The model's source, full revision, weights hash, license and base model are in the app's CycloneDX parts list,
[`docs/sbom/app.cdx.json`](../sbom/app.cdx.json). `scripts/check_bom.py` runs on every commit and fails if the
hash there is not the one inside the signed bundle.

## Limits
- The signature says **we** checked and signed this exact model; it does not prove the upstream model is
  free of problems. Its source and hash are pinned, and the app never lets the model decide a fact or a
  flag (ADR 0005).
- One key, held by the project owner, with no transparency log (no Sigstore Rekor entry). A real
  deployment would sign in CI with a key held in a hardware or cloud key store, or keyless with Sigstore.
- The phone is **stricter** than the official tool in one way: the official verifier skips git files such as
  `.gitattributes`; the phone refuses any file the signature does not list. Sign only the files the app loads.
- Only the signing key's holder can sign a model; a model update needs a new signature, not a new app.
