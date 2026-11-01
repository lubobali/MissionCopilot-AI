# Security policy

## Reporting a vulnerability
Please report it privately: open the **Security** tab of this repository and choose
**Report a vulnerability**. Do not open a public issue for a security problem.

Please include what you found, how to reproduce it, and what an attacker could do with it.
You can expect a first answer within 7 days. Fixes are tracked privately until they are released.

## What this project is
MissionCopilot is a **portfolio project**, built in public. It is **not independently audited**, not
certified, and there is no bug bounty. All data in the repository is fictional.

## Scope
In scope: the iOS app in `ios/`, the backend in `backend/`, the scripts in `scripts/`, and the CI
workflows in `.github/`. The AI Lab app in `ios/AILab/` is a debug-only spike app; reports about it are
welcome but it is not meant to ship.

## How security is handled
- [Threat model](docs/threat-model.md): every known threat with its control and status (built, spike,
  planned or accepted), checked in CI so it cannot claim more than the code shows.
- [How field data is protected](docs/security.md), and the decisions behind it in
  [docs/adr/](docs/adr/).
- CI runs secret scanning, a dependency audit, CodeQL and OpenSSF Scorecard; actions are pinned to
  commit SHAs; Dependabot proposes updates.

## Supported versions
Only the latest commit on `main` is supported.
