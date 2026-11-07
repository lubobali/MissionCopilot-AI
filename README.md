# MissionCopilot-AI

[![CI](https://github.com/lubobali/MissionCopilot-AI/actions/workflows/ci.yml/badge.svg)](https://github.com/lubobali/MissionCopilot-AI/actions/workflows/ci.yml)
[![License: All rights reserved](https://img.shields.io/badge/license-all%20rights%20reserved-red.svg)](LICENSE)

Small, offline AI for evidence-first field supervision. It runs on the iPhone in airplane mode,
keeps sensitive notes on the phone, links every fact to its evidence, and only shares a report
after a human approves it. **An untraceable claim cannot be approved.**

> Status: in development. Iterations 0 to 5 done (Nov 5 2026): the encrypted store and the mission pack are built and proven on a real iPhone; field flows (Iteration 6) are next. Portfolio project. Synthetic data only.

## How this project is run

Agile, SAFe style, by one developer working with AI coding agents (so iterations are one day).

| What | Where |
|---|---|
| Kanban board | [MissionCopilot-AI board](https://github.com/users/lubobali/projects/1) |
| Epic and stories | [Issues](https://github.com/lubobali/MissionCopilot-AI/issues) (epic, story, enabler, spike) |
| Iterations | [Milestones](https://github.com/lubobali/MissionCopilot-AI/milestones) |
| Definition of Done | [docs/agile/definition-of-done.md](docs/agile/definition-of-done.md) |
| Iteration reviews | [docs/agile/iteration-reviews.md](docs/agile/iteration-reviews.md) |
| Architecture decisions | [docs/adr/](docs/adr/) |

Every story is built test-first on its own branch and merged by a pull request that closes its
issue, with CI green.

### How CI runs (#127)
- **iOS** ([ios.yml](.github/workflows/ios.yml)): the app job (SwiftLint, the Staging and Release
  server check, build, then the 612 tests on a simulator) and the lab job (spikes 14 to 16) run side by
  side. The labs run on every push to main, every Monday, on demand, and on any pull request that
  touches them ([scripts/ios_ci_paths.py](scripts/ios_ci_paths.py), our own `git diff`); one
  "iOS result" check passes only when every needed job did. Measured: a pull request waits about
  13 minutes (it was 22). The floor is the simulator's first boot on a fresh runner, about 6 minutes.
- **Everything else** ([ci.yml](.github/workflows/ci.yml), [security.yml](.github/workflows/security.yml)):
  the same hooks as a local commit, a dependency audit, CodeQL and OpenSSF Scorecard.
- **Safety:** every action pinned by its full commit SHA, least privilege (no write permission), tool
  downloads checked by SHA-256, no caches for builds or packages (measured: they would save about a
  minute and could be poisoned), workflows linted by zizmor.

## What it does
Built so far (each part test-first, the store and the pack proven on an iPhone 13 Pro Max):
- **Connect a phone**: a one-time code, a signing key born in the phone's Secure Enclave, a manager approves it.
- **Download a mission pack**: signed by the organization's server, every file checked; it survives a cut
  signal, the phone locking and a server restart, and an update fetches only the files that changed
  ([pack proof](docs/pack-proof.md)).
- **Before you go**: open a mission and the phone checks itself for the field: the pack, the AI model
  (inside the app, checked against its signature), the speech languages the mission needs, free space;
  what is missing says what to do while still online.
- **Keep it on the phone, encrypted**: one key per mission, a 14-day lease, a hash-chained audit log, an app
  lock; it works in airplane mode ([store proof](docs/store-proof.md)).
- **Destroy it on order**: a revoked phone gets a signed shred order and the missions are destroyed.
- Next: the field work itself (document scan, red flags, voice debrief, the checklist), then the report.

## Architecture
**One-page summary: [docs/architecture-summary.md](docs/architecture-summary.md).** See [docs/architecture.md](docs/architecture.md): system context, containers, trust boundaries and the offline line. [docs/data-classification.md](docs/data-classification.md): labels, lifecycle and the data map. [docs/domain-model.md](docs/domain-model.md): the shared objects and their rules. Decisions in [docs/adr/](docs/adr/).

### Where it runs
```mermaid
flowchart LR
    phone(["iPhone app<br/>(works offline)"]) -- "HTTPS, TLS 1.2+,<br/>signed requests" --> nginx["nginx on a<br/>shared server"]
    nginx -- "127.0.0.1 only" --> api["MissionCopilot API<br/>(container)"]
    api -- "internal network,<br/>no internet" --> db[("Postgres<br/>one database per organization")]
    db -. "nightly, encrypted" .-> backup[("Backups<br/>private bucket")]
```
Staging and prod are two separate copies of the right side. Details: [ADR 0013](docs/adr/0013-hosting-on-a-shared-server.md), [deploy/RUNBOOK.md](deploy/RUNBOOK.md).

## Security
How field data is protected on the phone (three encryption layers, per-mission crypto-shred, honest limits):
**[docs/security.md](docs/security.md)**. Proven on a real iPhone in [spike #16](docs/spikes/03-encryption.md),
including a check you can repeat yourself, then built in the app and run on the iPhone again
([store proof](docs/store-proof.md)). Not independently audited.

**Reviewing security?** Start with the one-page path: **[docs/security-review.md](docs/security-review.md)**
(threat model, OWASP MASVS matrix, data handling, prompt-injection results, model signing, each with a check
you can run).

## How to run
(filled in as components ship)

## Tests
Backend and tooling: `uv run --directory backend pytest`. iOS: Swift Testing on the simulator.
The app has three builds: Debug (the local server), Staging (its own app, "MC Staging") and Release
(production only); see [docs/security.md](docs/security.md#which-phones-may-send-data-device-enrollment).
Every commit runs the same checks as CI through prek hooks.

## License
**All rights reserved** (see LICENSE). This repository is public to be read, for example to evaluate the
author's work; copying, using, running or changing any of it needs his written permission.
The logo (the L and the key, in `ios/MissionCopilot/Assets.xcassets`), the app icon that shows it and the
airplane mark belong to Lubo Bali, like the code.
AI models are not stored in this repo. Each model keeps its own license, listed in the
architecture decision records.
