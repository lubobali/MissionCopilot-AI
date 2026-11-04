# MissionCopilot backend

FastAPI sync backend: mission packs, approvals and the audit log, behind the API contract in
[docs/api/openapi.yaml](../docs/api/openapi.yaml). Security decisions and their tests:
[docs/threat-model.md](../docs/threat-model.md).

## Run and test
```
uv run --directory backend pytest            # tests
uv run --directory backend missioncopilot-backend   # the server, by default on 127.0.0.1:8110 (needs the databases below)
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
uv run --directory backend missioncopilot-admin make-signing-key  # once: signs packs and shred orders
uv run --directory backend missioncopilot-admin publish-demo-pack # the Kandor roads pack, next version
uv run --directory backend missioncopilot-admin convert-checklist form.xlsx --out form.json  # try a form (no database)
uv run --directory backend missioncopilot-admin publish-demo-pack --checklist form.xlsx      # publish with it
uv run --directory backend missioncopilot-admin issue-code kandor-works officer-7   # a phone's one-time code
uv run --directory backend missioncopilot-admin approve-device <id> --by <you>      # never your own phone
cd backend && MISSIONCOPILOT_DIRECTORY_URL_FILE=.db-addresses/directory.url \
  MISSIONCOPILOT_ORG_URLS_DIR=.db-addresses/orgs \
  MISSIONCOPILOT_SIGNING_KEY_FILE=.keys/signing-key.pem uv run missioncopilot-backend
```
The whole phone path (enroll, approve, signed pack download, revoke, shred) runs end to end against
this local server with `uv run --directory backend python ../scripts/e2e_phone_local.py`.

Addresses with passwords live in `backend/.db-addresses` (gitignored, owner-only files) and are never
printed. The server never migrates by itself, and it refuses to start if a database is missing,
behind the code, or named differently from the directory.

Those local defaults (`backend/.env`, `.db-addresses`, `.keys`) apply only when the admin runs from a
repo checkout. Installed on a server there are none: `MISSIONCOPILOT_ADDRESS_DIR` and
`MISSIONCOPILOT_SIGNING_KEY_FILE` must be set, so no secret ever lands inside the installed package.
The pack contract and the demo dataset ship inside the package (copies of `docs/`, kept equal by a
test), so publishing works with no repo around.

## Settings (environment variables)
Nothing configured means **production**, the safe default. An unknown value stops the start.

| Variable | Default | Meaning |
|---|---|---|
| `MISSIONCOPILOT_ENV` | `production` | `production`, `development` or `test`. API docs pages exist only outside production. |
| `MISSIONCOPILOT_ALLOWED_HOSTS` | `localhost,127.0.0.1` | Host names this server answers to; others get 400. No wildcard. |
| `MISSIONCOPILOT_ALLOWED_ORIGINS` | none | Browser origins allowed to call the API (the dashboard). No wildcard. |
| `MISSIONCOPILOT_DIRECTORY_URL` (or `_FILE`) | required | The directory database's app login address. |
| `MISSIONCOPILOT_ORG_URLS_DIR` | required | A folder with `<org id>.url` per organization (owner-only files). |
| `MISSIONCOPILOT_SIGNING_KEY_FILE` | required | The P-256 key that signs mission packs and shred orders (owner-only file; never as a variable). |
| `MISSIONCOPILOT_HOST` | `127.0.0.1` | Address to listen on (an IP address, never a name). In a container: `0.0.0.0`, published on loopback only. |
| `MISSIONCOPILOT_PORT` | `8110` | Port to listen on. |
| `MISSIONCOPILOT_FORWARDED_ALLOW_IPS` | none | The reverse proxy whose `X-Forwarded-For` is believed: addresses or networks, never `*`. See below. |
| `MISSIONCOPILOT_RATE_LIMIT_PER_MINUTE` | `600` | Per client address: loose, only against floods (officers share addresses). |
| `MISSIONCOPILOT_DEVICE_RATE_LIMIT_PER_MINUTE` | `120` | Per phone, after its signature checked out (a 50 MB pack is about 55 requests). |
| `MISSIONCOPILOT_MAX_BODY_BYTES` | `1048576` | Largest request body (413 above it). |
| `MISSIONCOPILOT_MIN_APP_BUILD` | `0` (off) | Oldest phone build served (`X-App-Build`); older, missing or garbled: 403 `app_too_old`, before the signature check. Health is never refused. |

Secret files must be owner-only (`chmod 600`) **and owned by the user the server runs as**; anything
else stops the start with what to fix.

Production refuses to start, listing every problem at once, when: the host allow-list names only
this machine; it listens beyond loopback with no trusted proxy (every phone would look like the
proxy); a browser origin is not https; or a limit is outside 60-6000 (address), 30-1200 (phone),
64 KiB-10 MiB (body). It logs one line at start with what runs, including the signing key's id
(the fingerprint the app pins), and nothing secret.

## What every request goes through
1. Security headers on every answer (nosniff, no framing, a `'none'` content policy, no-referrer,
   no-store; HSTS in production).
2. Host check, then rate and size limits (429 with Retry-After, 413).
3. Browser origin check (CORS, no credentials).
4. People (dashboard): an ES256 bearer token from the configured issuer, with roles; the
   organization and user come only from the token. Until an issuer is configured (Phase 8), every
   token route refuses every request. Phones: no token at all; each request is signed by the
   phone's enrolled Secure Enclave key (see docs/security.md), then counted against that phone's own
   limit (a refused request does not use up its sequence number). Only `/v1/health` (which also
   sends the server's time, so a phone can correct its clock for the 300 s signature window) and
   `/v1/devices/enroll` (authenticated by its one-time code) need neither.
5. Data only from the caller's organization's own database, as the caller: another team's or
   another organization's mission answers exactly like a missing one. Phones download their
   mission's signed pack (manifest, signature, files by SHA-256, resumable with byte ranges).
6. Errors as RFC 9457 Problem Details; a crash shows no stack trace; bad input is never echoed.
7. Security events go to an append-only, hash-chained audit log, never with tokens or bodies.

## Behind a reverse proxy
By default the server believes no `X-Forwarded-For` at all, not even from loopback (on a shared
server other programs can reach loopback), and sends no `Server` header. Behind a proxy, set
`MISSIONCOPILOT_FORWARDED_ALLOW_IPS` to that proxy only. With the proxy on the host and the server
in a container, the server sees the proxy as the **gateway of the container's own Docker network**,
not 127.0.0.1, so that gateway is the address to name. The proxy must overwrite the header with the
client's address (`X-Forwarded-For $remote_addr`), and send the real `Host`. The rate limit and the
audit log then see each phone's own address. Add a loose limit at the proxy too: each server
process keeps its own counts.
