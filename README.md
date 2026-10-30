# MissionCopilot-AI

[![CI](https://github.com/lubobali/MissionCopilot-AI/actions/workflows/ci.yml/badge.svg)](https://github.com/lubobali/MissionCopilot-AI/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Small, offline AI for evidence-first field supervision. It runs on the iPhone in airplane mode,
keeps sensitive notes on the phone, links every fact to its evidence, and only shares a report
after a human approves it. **An untraceable claim cannot be approved.**

> Status: in development (Iteration 1 · Architecture). Portfolio project. Synthetic data only.

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

## What it does
(filled in as features ship)

## Architecture
See [docs/architecture.md](docs/architecture.md): system context, containers, trust boundaries and the offline line. [docs/data-classification.md](docs/data-classification.md): labels, lifecycle and the data map. [docs/domain-model.md](docs/domain-model.md): the shared objects and their rules. Decisions in [docs/adr/](docs/adr/).

## How to run
(filled in as components ship)

## Tests
Backend and tooling: `uv run --directory backend pytest`. iOS: Swift Testing on the simulator.
Every commit runs the same checks as CI through prek hooks.

## License
Code: MIT (see LICENSE).
AI models are not stored in this repo. Each model keeps its own license, listed in the
architecture decision records.
