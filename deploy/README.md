# Deploying the MissionCopilot backend

One compose file, [compose.yaml](compose.yaml), runs staging and production on a shared Linux
server behind the host's reverse proxy (nginx, which holds the TLS certificate). Each environment
is its own compose project (`missioncopilot-staging`, `missioncopilot-prod`) with its own
Postgres, networks, volume, port and secrets: nothing is shared between them or with other apps.
The step-by-step runbook (first deploy, update, roll back, restore) comes with #103 step 6.

## The values file

Each environment has one values file on the server (never in git), passed with `--env-file`:

```
docker compose --env-file /srv/missioncopilot/prod/values.env -f deploy/compose.yaml up -d --wait
```

| Value | Example | Meaning |
|---|---|---|
| `MC_ENV` | `prod` | Names the project (`missioncopilot-prod`): every container, network and volume starts with it |
| `MC_IMAGE` | `ghcr.io/<owner>/missioncopilot-backend@sha256:<digest>` | The server image, always by digest |
| `MC_PORT` | `8120` | The loopback port the reverse proxy connects to (`127.0.0.1` only) |
| `MC_HOSTNAME` | `api.example.org` | The public DNS name; the only host name the API answers besides `127.0.0.1` |
| `MC_EDGE_SUBNET`, `MC_EDGE_GATEWAY` | `10.99.0.0/25`, `10.99.0.1` | The API's network. The host's reverse proxy reaches the container from this gateway, so it is the one address whose `X-Forwarded-For` is believed |
| `MC_DB_SUBNET` | `10.99.0.128/25` | Postgres's internal network (no internet) |
| `MC_SECRETS` | `/srv/missioncopilot/prod/secrets` | This environment's secrets folder (below) |
| `MC_MIN_APP_BUILD` | `0` | Optional: the oldest phone build served (0: all) |

Subnets are always written out: on a busy server Docker's automatic pool may be used up or may
pick a range that clashes with the host's own routes. Pick ranges no network, route or VPN on the
server uses, and different ones for each environment.

## The secrets folder

Every file is readable by **one** user only: the user its container runs as. The code refuses a
file anyone else can read, and says so when it cannot read one.

| Path in `MC_SECRETS` | Owner (uid) | Mode | What |
|---|---|---|---|
| `.` | root | `0711` | The folder itself: containers may pass through, nobody may list it |
| `pg_admin_password` | `999` (the Postgres image's user) | `0600` | The Postgres superuser's password, used once by the image to create the cluster |
| `admin_url` | `10001` (the server image's user) | `0600` | `postgresql://missioncopilot_admin:<password>@postgres:5432/postgres`, for `migrate` and `admin` only; the API never gets it |
| `addresses/` | `10001` | `0700` | Written by `admin setup` and `admin add-org`: `directory.url` and `orgs/<org>.url`, the app logins' addresses (each `0600`) |
| `keys/` | `10001` | `0700` | Written by `admin make-signing-key`: `signing-key.pem`, the key that signs packs and shred orders (`0600`) |

The admin writes into `addresses/` and `keys/` from inside the compose network, so every address
says `host=postgres`, and every file it writes already has the right owner and mode.

## Operator commands

Always `run --rm`, so no container (and no one-time code in its log) is left behind:

```
docker compose --env-file <values> -f deploy/compose.yaml run --rm admin setup
docker compose --env-file <values> -f deploy/compose.yaml run --rm admin add-org <org id>
docker compose --env-file <values> -f deploy/compose.yaml run --rm admin make-signing-key
docker compose --env-file <values> -f deploy/compose.yaml run --rm admin issue-code <org> <user>
```

`up` runs the migration first (the one-shot `migrate` service) and starts the API only when it
succeeds. After `add-org`, restart the API: organizations are loaded at start.

## Checking it

[scripts/container_check.py](../scripts/container_check.py) builds the image, runs this compose
file as a throwaway project, and checks what a phone and an attacker would meet (host names, the
client address through the proxy, read-only, no capabilities, no database port, no way out for
the database). It removes everything afterwards.
