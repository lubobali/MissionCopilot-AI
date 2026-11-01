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

## Limits
- The signature says **we** checked and signed this exact model; it does not prove the upstream model is
  free of problems. Its source and hash are pinned, and the app never lets the model decide a fact or a
  flag (ADR 0005).
- One key, held by the project owner, with no transparency log (no Sigstore Rekor entry). A real
  deployment would sign in CI with a key held in a hardware or cloud key store, or keyless with Sigstore.
