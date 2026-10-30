# Iteration reviews

One short review at the end of each iteration: what was done, what we learned, what changes next.
This project is built by one developer working with AI coding agents, so iterations are one day.

## Iteration 0 · Foundations (done Oct 30 2026)
**Done:** public repo and private mirror, TDD toolchain (uv, pytest, Ruff, ty, prek hooks), CI on
GitHub with a Linux job and a macOS job, XcodeGen project, first app running on a real iPhone 13 Pro Max,
ADR 0001 (native iOS + Python backend) and ADR 0002 (XcodeGen).

**Learned:**
- A model bake-off on the real phone before any code: LFM2.5 1.2B ran at about 38 tokens per second,
  but every tested model invented numbers. Decision: code does all the math, the model only writes.
- Pinning matters: "ubuntu-latest" was about to move to a new OS, so the runner image is pinned.
- A small warning hid a real problem: tests in one folder ran without the strict settings.
- Hooks must match CI exactly, or local and CI drift apart.

**Next:** Iteration 1 · Architecture.

## Iteration 1 · Architecture (done Oct 30 2026)
**Done:** system context and container diagrams with trust boundaries; data classification with
inherited labels; ADRs 0003-0011; domain model; OpenAPI 3.1 contract with tests; fictional demo dataset
with tests; architecture summary and review; Agile setup (board, Definition of Done, reviews).

**Learned:**
- Guards beat manual checks: the ADR guard caught a heading a manual check missed, and a hook gap would
  have let contract-only changes skip the contract tests.
- CI speed matters: docs-only PRs waited up to 12 minutes for a macOS runner; path filters cut that to
  about 15 seconds.
- Mutation checks (break the data on purpose) prove that tests really protect what they claim.
- The review found an accessibility gap; it is now in the Definition of Done.

**Next:** Iteration 2 · Feasibility spikes on the real iPhone.
