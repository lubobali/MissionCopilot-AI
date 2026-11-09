# Security review: start here

A 10-minute path for a security reviewer. MissionCopilot-AI is a prototype of an offline iPhone app for
field monitoring missions, with a Python backend. It uses **fictional data only** (the made-up country
Kandor). Everything below is a **self-assessment, not an independent audit**. Each claim points at the
code or test behind it, and most can be checked with one command from the repository root.

## The 10-minute path

| Min | Read | What it shows | Check it yourself |
|---|---|---|---|
| 1 | [security.md](security.md) | How data is protected on the phone and the server, and what is **not** protected | |
| 2 | [threat-model.md](threat-model.md) | Every threat and privacy risk (86 on Nov 8: 78 threats, 8 privacy risks), each built, spike, planned or accepted, with its proof | `python3 scripts/check_threat_model.py` |
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
  model signature check, the app lock.
- **Built in the app and proven on a real iPhone 13 Pro Max** ([store proof](store-proof.md)): the encrypted
  store that pauses before the phone locks, mission keys in the Secure Enclave with a 14-day lease,
  crypto-shred, signed and sealed evidence, facts that trace back to it. The phone found two bugs the
  simulator hid, both fixed. Check the phone's signed chain with the server's own code:
  `uv run --directory backend pytest tests/unit/test_evidence_v2.py`.
- **Built and proven on the iPhone against the real staging server** ([pack proof](pack-proof.md)):
  connecting with a one-time code and a chip key, signed mission packs checked file by file, a download that
  survives a cut signal, the phone lock and a server restart, a shred order judged by the server's time, a
  phone that connects again after its shred. The phone found 11 bugs the simulator hid, all fixed.
- **Built in the app and proven on the iPhone offline** ([field proof](field-proof.md)): scanned facts
  checked on their pages, corrections checked the same way, red flags by cited rules, voice debriefs with
  notes written by code and every number read back, Ask answered by code from the mission's records, the
  model only choosing. Raw spike results are in [spikes/results](spikes/results).

## Honest limits
- **Not audited.** No external penetration test or audit yet; that is an open item before any real use.
- **No protection on a compromised phone** (jailbreak, malware) and no App Attest: those need a paid Apple
  team and device management, which a real deployment would add.
- **A forced unlock shows the active missions.** Least data and expiring keys limit what that is.
- **The phone proofs are one phone,** one iOS version, Debug and Staging builds, a lock of about two minutes
  and a background pause of about nine.
- **The prompt-injection set is small and ours:** 30 attacks, one model, nobody adapting to the checks.
- **Much is still spike or planned:** see the status columns; nothing is claimed without its proof.

## Report a problem
Please use private vulnerability reporting, as described in [SECURITY.md](../SECURITY.md).
