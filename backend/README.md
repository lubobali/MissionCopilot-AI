# MissionCopilot backend

FastAPI sync backend: mission packs, approvals and the audit log, behind the API contract in
[docs/api/openapi.yaml](../docs/api/openapi.yaml). Security decisions and their tests:
[docs/threat-model.md](../docs/threat-model.md).

## Run and test
```
uv run --directory backend pytest            # tests
uv run --directory backend missioncopilot-backend   # local server on 127.0.0.1:8110 (needs the databases below)
```

The database tests (`tests/db`) need a local Postgres 18. Once per machine, then whenever Docker
restarts:
```
uv run --directory backend python ../scripts/make_dev_env.py   # random password into backend/.env
docker compose --project-directory backend up -d --wait          # Postgres on 127.0.0.1:55432
```
`backend/.env` is gitignored and readable by its owner only. CI starts the same pinned image with a
fresh random password on every run.

## Databases (ADR 0008)
- **Directory**: phones, enrollment codes and the security audit log: what the server must find before
  it knows the caller's organization. Ids only, never mission data.
- **One database per organization**, with an owner role that cannot log in (it owns the tables) and an
  app login that reads and writes rows only. One organization's login cannot connect to another's
  database. Inside, forced row-level security shows each person only their team's missions.

Set up locally and load the fictional Kandor demo, then start the server:
```
uv run --directory backend missioncopilot-admin setup       # the directory and its own login
uv run --directory backend missioncopilot-admin seed-demo   # org kandor-works, two missions, three people
uv run --directory backend missioncopilot-admin migrate     # after pulling new migrations
cd backend && MISSIONCOPILOT_DIRECTORY_URL_FILE=.db-addresses/directory.url \
  MISSIONCOPILOT_ORG_URLS_DIR=.db-addresses/orgs uv run missioncopilot-backend
```
Addresses with passwords live in `backend/.db-addresses` (gitignored, owner-only files) and are never
printed. The server never migrates by itself, and it refuses to start if a database is missing,
behind the code, or named differently from the directory.

## Settings (environment variables)
Nothing configured means **production**, the safe default. An unknown value stops the start.

| Variable | Default | Meaning |
|---|---|---|
| `MISSIONCOPILOT_ENV` | `production` | `production`, `development` or `test`. API docs pages exist only outside production. |
| `MISSIONCOPILOT_ALLOWED_HOSTS` | `localhost,127.0.0.1` | Host names this server answers to; others get 400. No wildcard. |
| `MISSIONCOPILOT_ALLOWED_ORIGINS` | none | Browser origins allowed to call the API (the dashboard). No wildcard. |
| `MISSIONCOPILOT_DIRECTORY_URL` (or `_FILE`) | required | The directory database's app login address. |
| `MISSIONCOPILOT_ORG_URLS_DIR` | required | A folder with `<org id>.url` per organization (owner-only files). |

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
5. Data only from the caller's organization's own database, as the caller: another team's or
   another organization's mission answers exactly like a missing one.
6. Errors as RFC 9457 Problem Details; a crash shows no stack trace; bad input is never echoed.
7. Security events go to an append-only, hash-chained audit log, never with tokens or bodies.

## Behind a reverse proxy
The rate limit uses the connection's own address and does not trust `X-Forwarded-For`. Behind a
proxy, run uvicorn with `--proxy-headers --forwarded-allow-ips=<that proxy only>` and
`--no-server-header`, and add a limit at the proxy too: each process keeps its own counts.
