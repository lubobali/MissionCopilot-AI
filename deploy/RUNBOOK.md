# Runbook: MissionCopilot backend on a shared server

How the backend is put on a server that also runs other apps, kept up to date, rolled back and
restored. Every procedure here was run on staging (#103 step 6) or is run by
`scripts/container_check.py` in CI. Each step has a **check** and a **way back**.

All commands run as root over the admin VPN, from the repo clone (`/srv/missioncopilot-dev`, on
`main`). `<env>` is `staging` or `prod`. Shortcuts used below:

```
V=/srv/missioncopilot/<env>/values.env
C="docker compose --env-file $V -f deploy/compose.yaml"
B="--values $V --restic-env /srv/missioncopilot/<env>/backup.env --password-file /srv/missioncopilot/backup/restic-password"
```

## The rules on a shared server

1. Touch only our own things: containers, networks and volumes named `missioncopilot-*`, our
   folders under `/srv/missioncopilot*`, our nginx file, our certificate, our systemd units.
2. Back up before any change outside our folders (account files, `/etc/nginx`, `/etc/letsencrypt`)
   and record every other site's answer before a reload, to compare after.
3. nginx: `nginx -t` before every **reload**; never restart; never `certbot --nginx`.
4. Never `docker system prune -a` (it deletes other apps' images), never restart Docker (it stops
   every app on the server), never change the firewall, the VPN or Docker's own settings.
5. Never let Docker pick a subnet: every network is written out in the values file.
6. Deploy images by digest only, never by tag.

## What is where

| What | Where |
|---|---|
| Values (what runs where) | `/srv/missioncopilot/<env>/values.env` (root, 0600); see `deploy/README.md` |
| Secrets | `/srv/missioncopilot/<env>/secrets/` (owners and modes in `deploy/README.md`) |
| Backup settings | `/srv/missioncopilot/<env>/backup.env`, `/srv/missioncopilot/backup/restic-password` (root, 0600; keep a copy off the server) |
| Accounts | `missioncopilot` (10120, the server image) and `missioncopilot-db` (10121, Postgres): no login |
| nginx | `/etc/nginx/sites-available/<hostname>`, linked in `sites-enabled`; logs `/var/log/nginx/missioncopilot-<env>.*` |
| Timers | `missioncopilot-backup@<env>.timer` (daily 07:15 UTC), `missioncopilot-backup-check@<env>.timer` (Sundays 08:00 UTC) |

## First deploy of an environment

### 1. Accounts (once per server)
```
groupadd --system --gid 10120 missioncopilot && useradd --system --uid 10120 --gid 10120 \
  --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin missioncopilot
groupadd --system --gid 10121 missioncopilot-db && useradd --system --uid 10121 --gid 10121 \
  --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin missioncopilot-db
```
First check that nothing uses those numbers (`getent passwd 10120`, `ps -eo uid= | grep -w 10120`,
and the `User` of every container). **Check:** `id missioncopilot`; the shadow entry is `!`.
**Way back:** `userdel missioncopilot; userdel missioncopilot-db`.

### 2. Folders, values and secrets
```
install -d -m 711 /srv/missioncopilot /srv/missioncopilot/<env> /srv/missioncopilot/<env>/secrets
install -d -m 700 -o 10120 -g 10120 /srv/missioncopilot/<env>/secrets/{addresses,keys}
```
Write `values.env` (0600; `MC_MIN_APP_BUILD=0` until the phone sends `X-App-Build`), then one
random password into `secrets/pg_admin_password` (owner 10121, 0600) and the same password in
`secrets/admin_url` as `postgresql://missioncopilot_admin:<password>@postgres:5432/postgres`
(owner 10120, 0600), with `umask 077`. **Check:** `$C config -q`; owners and modes as in
`deploy/README.md`. **Way back:** remove the folder.

### 3. Database, organizations, signing key
```
$C up -d --wait postgres
$C run --rm -T admin setup
$C run --rm -T admin add-org kandor-works        # and kandor-e2e on staging, for the end to end
$C run --rm -T admin seed-demo
$C run --rm -T admin make-signing-key           # prints the PUBLIC half only, for the app
$C run --rm -T admin publish-demo-pack
```
**Check:** every line says `OK`; Postgres runs as 10121 with no capabilities and no port.
For prod, make a spare key too (rotation, below) and move its private file off the server.
**Way back:** `$C down -v` (deletes this environment's database: only on a first deploy).

### 4. The API
```
python3 scripts/mc_deploy.py deploy --values $V --image ghcr.io/lubobali/missioncopilot-backend@sha256:<digest>
```
Take the digest from the image workflow's run summary on `main` (attested). **Check:** `OK ...
is up and ready`; the start line (`$C logs api | head`) shows the right hosts, the trusted proxy
(the edge gateway) and the signing key id; `curl -H "Host: <hostname>" 127.0.0.1:<port>/v1/ready`.
**Way back:** `$C down` (keeps the volume).

### 5. nginx and the certificate
Back up `/etc/nginx` and `/etc/letsencrypt` (tar, 0600) and record every site's answer first.
```
python3 scripts/render_nginx_site.py --http-only --env <env> --hostname <hostname> --port <port> \
  > /etc/nginx/sites-available/<hostname>
ln -s /etc/nginx/sites-available/<hostname> /etc/nginx/sites-enabled/<hostname>
nginx -t && systemctl reload nginx
certbot certonly --webroot -w /var/www/certbot -d <hostname> --cert-name <hostname> \
  --non-interactive --agree-tos --dry-run                      # then the same without --dry-run,
                                                               # plus --deploy-hook "systemctl reload nginx"
python3 scripts/render_nginx_site.py --env <env> --hostname <hostname> --port <port> \
  > /etc/nginx/sites-available/<hostname>
nginx -t && systemctl reload nginx
```
**Check:** after each reload every other site answers as before; `https://<hostname>/v1/ready`;
TLS 1.0 and 1.1 refused, 1.2 and 1.3 accepted (`openssl s_client -tls1_1 -cipher
'DEFAULT:@SECLEVEL=0'`: the client must really offer them); no other renewal file changed.
**Way back:** remove our file and its link, `nginx -t`, reload; `certbot delete --cert-name <hostname>`.

### 6. Backups
```
python3 scripts/mc_backup.py init $B
python3 scripts/mc_backup.py backup $B
python3 scripts/mc_backup.py restore-check $B
install -m 644 deploy/systemd/* /etc/systemd/system/ && systemctl daemon-reload
systemctl start missioncopilot-backup@<env> missioncopilot-backup-check@<env>   # once, by hand
systemctl enable --now missioncopilot-backup@<env>.timer missioncopilot-backup-check@<env>.timer
```
**Check:** `restore-check` says OK; `systemctl list-timers 'missioncopilot-*'`; the bucket's
lifecycle keeps only the last version (restic deletes old data itself). **Way back:**
`systemctl disable --now` the timers.

## Update to a new image

1. `python3 scripts/mc_backup.py backup $B` (a fresh backup: the way back if a migration goes wrong).
2. `python3 scripts/mc_deploy.py deploy --values $V --image <image by digest>`.
3. **Check:** `OK ... is up and ready`; `https://<hostname>/v1/ready`.

If the new image does not come up, the script puts the previous one back by itself and says
`ROLLED BACK`. Staging first, always; prod only with the digest staging ran.

## Roll back

`python3 scripts/mc_deploy.py rollback --values $V` puts `MC_IMAGE_PREVIOUS` back. This works
when the new image ran no migration. The server refuses a database newer than its code (on
purpose), so once a migration ran, the way back is **restore** (below) with the backup from step 1
of the update. Migrations only add (expand first, remove in a later release), so most updates
never need this.

## Restore

The databases from the latest snapshot (or `--snapshot <id>` from `restic snapshots`):
```
python3 scripts/mc_restore.py $B --yes-replace-live-data
```
It stops the API, loads the roles, recreates every database as it was dumped (owner and who may
connect), starts the API and checks every table's rows. **Check:** `OK ... restored`; `/v1/ready`.

If the secrets folder is lost too: restore the snapshot with restic (`restic restore latest
--target /root/restore`), then `tar -xpf /root/restore/backup/secrets.tar --same-owner -C
/srv/missioncopilot/<env>/secrets` as root; remove `/root/restore` after.

## Rotate the signing key

The phone pins public keys and accepts any key it pins (`MC_SERVER_KEYS`). Signed packs carry
their key id; shred orders are signed with the server's current key.
1. Make the next key next to the current one (it never overwrites a file):
   `$C run --rm -T -e MISSIONCOPILOT_SIGNING_KEY_FILE=/run/mc/keys/next.pem admin make-signing-key`;
   it prints the public half for the app. Keep a copy of `next.pem` off the server.
2. Ship an app that pins the current **and** the next key; wait until phones have it.
3. Swap `secrets/keys/signing-key.pem` for the next key (owner 10120, 0600) and restart the API
   (`$C up -d --force-recreate api`); the start line shows the new key id.
4. Publish every live pack again (`admin publish-demo-pack`): the phone refuses packs signed by a
   key it no longer pins.
5. Later, ship an app that pins only the new key.

## Day to day

| Task | Command |
|---|---|
| A one-time code for a phone (15 minutes) | `$C run --rm -T admin issue-code <org> <user>` |
| Approve / revoke a phone | `$C run --rm -T admin approve-device <id> --by <you>` / `revoke-device` |
| A new organization | `$C run --rm -T admin add-org <org>`, then `$C up -d --force-recreate api` (organizations load at start) |
| Logs | `$C logs --tail 100 api`; nginx: `/var/log/nginx/missioncopilot-<env>.*` |
| Backups ran? | `journalctl -u 'missioncopilot-backup*' --since -2d` |
| Certificate renews? | `certbot renew --dry-run --cert-name <hostname>` |
| Clock synced? | `timedatectl` (signed requests allow 300 s; "System clock synchronized: yes") |

## Never

`docker system prune -a`; `systemctl restart docker` (stops every app on the server; Docker's
live-restore is off); `certbot --nginx`; editing another app's nginx file, network, container or
database; a `default_server`; publishing a port on anything but `127.0.0.1`; a password, key or
token in git, in an environment variable of the API, or in an issue.
