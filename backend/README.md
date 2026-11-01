# MissionCopilot backend

FastAPI sync backend: mission packs, approvals and the audit log, behind the API contract in
[docs/api/openapi.yaml](../docs/api/openapi.yaml). Security decisions and their tests:
[docs/threat-model.md](../docs/threat-model.md).

## Run and test
```
uv run --directory backend pytest            # tests
uv run --directory backend missioncopilot-backend   # local server on 127.0.0.1:8110
```

## Settings (environment variables)
Nothing configured means **production**, the safe default. An unknown value stops the start.

| Variable | Default | Meaning |
|---|---|---|
| `MISSIONCOPILOT_ENV` | `production` | `production`, `development` or `test`. API docs pages exist only outside production. |
| `MISSIONCOPILOT_ALLOWED_HOSTS` | `localhost,127.0.0.1` | Host names this server answers to; others get 400. No wildcard. |
| `MISSIONCOPILOT_ALLOWED_ORIGINS` | none | Browser origins allowed to call the API (the dashboard). No wildcard. |

Limits (in `Settings`): 120 requests a minute per client address, 1 MiB per request body.

## What every request goes through
1. Security headers on every answer (nosniff, no framing, a `'none'` content policy, no-referrer,
   no-store; HSTS in production).
2. Host check, then rate and size limits (429 with Retry-After, 413).
3. Browser origin check (CORS, no credentials).
4. People (dashboard): an ES256 bearer token from the configured issuer, with roles; the
   organization and user come only from the token. Until an issuer is configured (Phase 8), every
   token route refuses every request. Phones: no token at all; each request is signed by the
   phone's enrolled Secure Enclave key (see docs/security.md). Only `/v1/health` and
   `/v1/devices/enroll` (authenticated by its one-time code) need neither.
5. Data only from the caller's organization's own store; another organization's mission answers
   exactly like a missing one.
6. Errors as RFC 9457 Problem Details; a crash shows no stack trace; bad input is never echoed.
7. Security events go to an append-only, hash-chained audit log, never with tokens or bodies.

## Behind a reverse proxy
The rate limit uses the connection's own address and does not trust `X-Forwarded-For`. Behind a
proxy, run uvicorn with `--proxy-headers --forwarded-allow-ips=<that proxy only>` and
`--no-server-header`, and add a limit at the proxy too: each process keeps its own counts.
