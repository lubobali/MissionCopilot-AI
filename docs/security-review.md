# Security review: start here

A 10-minute path for a security reviewer. MissionCopilot-AI is a prototype of an offline iPhone app for
field monitoring missions, with a Python backend. It uses **fictional data only** (the made-up country
Kandor). Everything below is a **self-assessment, not an independent audit**. Each claim points at the
code or test behind it, and most can be checked with one command from the repository root.

## The 10-minute path

| Min | Read | What it shows | Check it yourself |
|---|---|---|---|
| 1 | [security.md](security.md) | How data is protected on the phone and the server, and what is **not** protected | |
| 2 | [threat-model.md](threat-model.md) | 60 threats and privacy risks, each built, spike, planned or accepted, with its proof | `python3 scripts/check_threat_model.py` |
| 1 | [masvs.md](masvs.md) | All 24 OWASP MASVS v2.1 controls with their official wording and status | `python3 scripts/check_masvs.py` |
| 1 | [data-handling.md](data-handling.md) | Every data item: where it lives, how long, encryption, who sees it, how it ends | `python3 scripts/check_data_handling.py` |
| 1 | [ADR 0012](adr/0012-lost-seized-or-coerced-phone.md) | A lost, seized or forced phone: expiring keys, signed shred order, no hidden wipe, staff card | `uv run --directory backend pytest tests/unit/test_shred_order.py` |
| 2 | [Prompt injection](spikes/08-prompt-injection.md) | 30 attacks on the real phone: 6 of 30 got through before the code checks, 0 of 30 after | `swift test` in `ios/AILab/DocumentLab` (the checks and the scorer) |
| 1 | [Model signing](models/README.md) | The on-device model is signed (OpenSSF Model Signing); the app refuses any changed file | The verify command in that page (official tool, pinned) |
| 1 | [Parts lists](sbom/app.cdx.json) | CycloneDX lists for the app (model, database libraries) and the backend (built in CI) | `python3 scripts/check_bom.py` |

**Everything at once:** `prek run --all-files` runs the same checks CI runs on every pull request: secret
scan, workflow lint, the guards above, the backend and script tests, and the iOS tests on the simulator.
CI adds a dependency audit, CodeQL and OpenSSF Scorecard ([security.yml](../.github/workflows/security.yml)).
Backend controls, each with its test: [backend/README.md](../backend/README.md).

## What is proven, and where
- **Built and tested** (backend and the main app): signed device requests with no token on the phone,
  organization isolation, strict input and limits, a hash-chained audit log, the signed shred order, the
  model signature check, the app lock's rules.
- **Proven on a real iPhone 13 Pro Max, offline** (lab code, rebuilt test-first in the app from Phase 4):
  the encrypted store and crypto-shred, signed evidence, expiring mission keys, document checks and the
  prompt-injection results. Raw results are in [spikes/results](spikes/results).

## Honest limits
- **Not audited.** No external penetration test or audit yet; that is an open item before any real use.
- **No protection on a compromised phone** (jailbreak, malware) and no App Attest: those need a paid Apple
  team and device management, which a real deployment would add.
- **A forced unlock shows the active missions.** Least data and expiring keys limit what that is.
- **The prompt-injection set is small and ours:** 30 attacks, one model, nobody adapting to the checks.
- **Much is still spike or planned:** see the status columns; nothing is claimed without its proof.

## Report a problem
Please use private vulnerability reporting, as described in [SECURITY.md](../SECURITY.md).
