# ADR 0013: Hosting on a shared server

- Status: accepted (Iteration 5, story #103 "the backend on a real server"; staging live, prod after the phone's end to end)
- Date: 2026-11-05

## Context
The backend has to run somewhere the phones can reach over the internet, with a real certificate (iOS
App Transport Security accepts nothing less), backed up, and cheap enough for a demo. The server
available is one virtual machine that already runs about fifteen other apps: their containers, their
databases, a reverse proxy with a dozen sites, a Kubernetes node for another project, nightly jobs.
Whatever MissionCopilot does there must never disturb them, and they must never reach MissionCopilot's
data.

What the server looked like when we started (read-only survey, #103 step 0):
- Docker's automatic address pools were all taken, and the next one in line overlapped the
  server's own default gateway: a network Docker picked by itself could have cut the server off.
- Host user ids are shared by every container. The Postgres image's user (999) and the usual
  pick for app images (10001) both belonged to other apps' processes there.
- A container reached from the host's nginx sees the Docker network's gateway as its client, not
  127.0.0.1 and not the phone.
- Docker's live-restore is off: restarting Docker stops every app on the server.

## Options
1. **A managed platform** (a PaaS with managed Postgres). Least operations, but per-organization
   databases with row-level security and owner-only secret files do not fit the usual offerings,
   and it moves the data to another provider.
2. **A separate server only for MissionCopilot.** Clean isolation, but one more machine to patch
   and pay for, for a demo.
3. **The server's existing Kubernetes.** It belongs to another project; sharing it would tie our
   uptime to theirs.
4. **Docker Compose on the shared server, fully boxed in**: own containers, networks, database,
   users, nginx site, certificate, backups and timers, nothing shared but the kernel and the host's
   nginx.

## Decision
Option 4, with staging and prod as two separate Compose projects on the same server, deployed by
image digest from CI, behind the host's nginx.

1. **Containers.** One image, built in CI natively for the server (linux/amd64), checked with the
   real Compose file, scanned, pushed only from `main` by digest with a build provenance
   attestation, public (the code is public; nothing secret is in a layer). The API runs read-only,
   with no capabilities and no new privileges; Postgres has no capabilities either; every container
   has memory, CPU, process and log limits.
2. **Own ids.** The server image runs as uid 10120 and Postgres as 10121, both with no-login
   accounts on the host so no one else takes those numbers.
3. **Own networks, written out.** Each environment has an `edge` network (the API) and an
   `internal` `db` network (Postgres, no internet), on subnets set in its values file; Docker never
   picks one.
4. **Loopback only, then nginx.** The API is published on `127.0.0.1` only. The host's nginx serves
   one site file of ours (TLS 1.2 and 1.3, a loose per-address limit with JSON 429 and `Retry-After`,
   JSON 503 when the API is down, packs untouched and resumable). The API believes
   `X-Forwarded-For` only from its own network's gateway.
5. **Own database per environment**, its own superuser, never shared with another app; one database
   per organization inside it (ADR 0008).
6. **Secrets as files**, each readable by the one uid that needs it (0600); the API never gets the
   admin login. Signing keys are made on the server, one per environment, plus an offline spare for
   prod; the phone pins public keys only.
7. **Backups**: an encrypted restic repository per environment in a private bucket of its own,
   nightly at a quiet hour, with a restore into a throwaway Postgres every week.
8. **Deploys by hand, by digest**, with a script that waits for `/v1/ready` and puts the previous
   image back by itself if the new one does not come up. No CI job can reach the server.

## Why
- **It fits the demo's cost and still shows the real thing:** a real certificate, a real network
  between phone and server, backups that restore.
- **Every isolation claim is tested, not assumed.** `scripts/container_check.py` runs the real image
  with the real Compose file, in CI and on the server, and checks 30 things: uid and capabilities,
  read-only, loopback only, Postgres without a port or internet, the phone's address through the
  proxy (and a forged one ignored), the nginx site's 429, 413 and 503, a backup restored into a
  throwaway Postgres, a lost database restored live, a deploy that cannot start going back by itself.
- **The other apps were checked around every change:** each nginx reload was followed by comparing
  every other site's answer, over https and http, with a baseline taken before the first one
  (nothing changed); after the accounts were added, every other site still answered.
- **The two id clashes and the address pool trap were found by looking, before deploying.** Using
  the images' defaults would have shared our secret files' owner with other apps.

## Consequences
- **Easier:** one place to look; staging proves every change before prod; a deploy or a restore is
  one command with a check (`deploy/RUNBOOK.md`).
- **Harder:** we share the kernel, the Docker daemon and the host's nginx. Anyone who controls
  Docker on the server controls our containers; a bad nginx reload would affect every site, hence
  `nginx -t` before every reload and only our own file. A Docker restart stops us with everyone
  else.
- **Watch:** memory on the server (swap was already mostly in use before we came; our containers
  have hard limits); the certificate's renewal (Let's Encrypt lifetimes shorten from February 2027;
  certbot renews by time left, not a fixed date); the nightly backup and the weekly restore test in
  the journal.
- The signing key is a file on a shared server: root there can read it. The hardware key store of
  ADR 0008 is still the plan for real users.

## Revisit when
- Real users or real (not fictional) mission data: a server of its own, encrypted disks, the
  signing key in a hardware key store (ADR 0008).
- The phones need the backend to survive a server outage (a second server and replication), or a
  deploy without the few seconds of 503 a restart gives today.
- The server's other apps grow enough to press on memory or CPU, or its operator changes Docker's
  daemon settings.
