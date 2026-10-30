# Definition of Done

A story is **Done** only when every line below is true.

## Code and tests
- Written test-first: the test failed for the right reason, then passed.
- All tests green locally and in CI (backend, scripts, iOS). No skipped or weakened tests.
- Lint, format and type checks clean (Ruff, ty, SwiftLint strict). Zero warnings.
- No file over 300 lines; no function over the complexity limit.

## Security and data
- No secrets in code or history (gitleaks clean).
- New data follows ADR 0008: encrypted, labelled, and only leaves the phone after approval.
- New facts and flags keep their lineage (source, rule and version).

## Product
- Acceptance criteria in the issue are all checked.
- App work is shown running on the real iPhone (offline when the story says offline).
- UI work is accessible: VoiceOver labels on every control, Dynamic Type supported, contrast checked.
- Docs updated: ADR changed if a decision changed, README if the way to run it changed.

## Delivery
- Merged through a pull request that closes the issue, with CI green.
- Board card moved to Done.
