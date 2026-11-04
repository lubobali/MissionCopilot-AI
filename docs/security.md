# How Mission Copilot protects field data

**Status: draft. Built test-first in the main app (Phase 4) and proven on an iPhone 13 Pro Max: the encrypted
store, its Keychain key, the protected folder and the pause on lock (#69),
per-mission keys in the Secure Enclave with the 14-day lease and recorded shreds (#70), signed, sealed
evidence (#71), facts and sentences that trace back to evidence with an append-only, hash-chained audit
log (#72), and the app lock (#73). The whole store was run on the iPhone, lock included
([store proof, #74](store-proof.md)). Not independently audited.** Every threat and its status: [threat model](threat-model.md).
Decision record: [ADR 0008](adr/0008-data-storage-isolation-encryption.md). Evidence and how to repeat it:
[spike #16](spikes/03-encryption.md).

## What it protects
Mission notes, photos, scans and recordings that a field officer collects, often offline, on a phone that can be
lost, stolen or inspected.

## Three layers on the phone
1. **iOS Data Protection, Complete.** Every file the app creates is encrypted by iOS and closes about 10 seconds
   after the phone locks. Measured: with the phone locked, the app itself could not read its database, read
   its key, or even write its own files.
2. **An encrypted database (SQLCipher).** Each user has their own database on this phone, with a random 256-bit
   key kept in the Keychain as "this device only, when unlocked". It never syncs to iCloud and cannot be
   restored to another phone. A copied database file is random bytes: no text, not even table names.
3. **A key for each mission, guarded by the Secure Enclave.** Notes are sealed with their mission's own key
   before they are stored. That key is kept only in wrapped form, locked by a Secure Enclave key made for
   that mission. The Secure Enclave is the phone's security chip; its private key never leaves it.

The data folder is excluded from backups, so mission data does not end up in personal iCloud or computer
backups.

## Destroying a mission (crypto-shred)
Deleting a mission's Secure Enclave key makes that mission's data unreadable at once, while other missions
stay readable. The encrypted rows can stay on disk for a moment; nothing can open them. They are then deleted.

Precisely: CryptoKit does not store the key inside the chip. The chip gives back an encrypted blob that only
this phone's chip can use, and the app keeps it in the Keychain. Shredding deletes that blob. A copy surviving
anywhere else is useless without this phone's chip.

## Evidence that shows tampering
Every photo, scan and recording is signed by the phone's Secure Enclave and linked to the item before it,
with a signed count and last link per mission. The signature covers the file's hash, the time and where
that time came from, the kind of item and the location ([signed evidence format](evidence-format.md)), so
none of them can be changed afterwards. Changing one byte, removing an item or cutting off the last one is
detected offline, and the server verifies the phone's signatures with only the public key, checking the
format strictly. Built in the app (#71): the app produces byte for byte what the server expects. On the
phone, each file and its signed record are sealed with the mission key, so a shred makes both unreadable.
Proven on the iPhone in [spike #17](spikes/04-signed-evidence.md); the app's version is proven on the phone
in the [store proof (#74)](store-proof.md), and the server verifies that chain. Limit: on the phone alone, rolling back to an older chain needs the server's sync receipt to be
caught.

## Which phones may send data (device enrollment)
A phone never holds a password or a login token. It is known by a key made inside its Secure Enclave,
and every request it sends is signed with that key.

1. **An admin issues a one-time code** for one named person's phone. The code is 128 random bits, works
   once, expires after 15 minutes, and the server keeps only its hash.
2. **The phone enrolls** with the code, its public key, and a signature that proves it holds the private
   key. It signs exactly `missioncopilot-enroll-v1\n` + code + `\n` + public key (DER). The phone is now
   *pending*.
3. **A manager approves it**, and never their own phone. A revoked phone can never be approved again.
4. **Every request is signed** over exactly `missioncopilot-request-v1\n` + method, path and query, device
   id, sequence number, Unix time and the body's SHA-256 (hex), one per line. The sequence number must
   rise with every request, so a captured request cannot be sent again; the time must be within 5
   minutes. A refused request never moves the sequence on, so forged requests cannot lock a phone out.
5. **A manager or admin can revoke a phone** at any time; its next signed request gets a shred order
   signed by the server. The phone checks it before acting (a pinned key, its own device id, issued in
   the last 5 minutes), then destroys every mission and records it; any other order changes nothing.
6. **The app side is built (#90):** the phone signs with its chip key, keeps a request number that only
   rises (at least the clock in milliseconds, so it never falls), pins the server's key by key id, and
   talks https only (plain http to the local server in Debug builds). Until the dashboard exists, an
   operator issues codes and approves phones with `missioncopilot-admin`. An end-to-end test runs the
   whole path against the real server (`scripts/e2e_phone_local.py`).
7. **The app on a real server (#104):** three builds. Debug talks to the laptop's server for the
   Simulator; Staging is its own app ("MC Staging", its own keychain, chip keys and pinned key) for
   `https://mc-staging.lubot.ai`; Release talks only to `https://mc.lubot.ai`. Checked three ways: the
   settings files, Xcode's own resolved settings, and the app, which refuses any other host (T57). A
   wrong phone clock no longer locks a phone out: it measures the server's time from `/v1/health` and
   signs with it (T59). A busy or restarting server pauses a download, which goes on by itself after
   the wait it shows, at most 5 tries in a row (T58). Every request says the app's build, so the server
   can answer "update the app" without anything on the phone being deleted (T60).

**Limits (honest):**
- **Trust on first use.** Without Apple's App Attest the server cannot prove that the key really lives in
  a Secure Enclave, or that the request comes from our unmodified app. Enrollment is the control: a
  short-lived code for one named person, and a manager who approves each phone.
- **A stolen code** lets a thief enroll their own key, but only as a pending phone that a manager must
  approve. A code is shown once and expires in 15 minutes.
- **No production key in the Release build yet.** It is added when the server makes it, with an offline
  spare (#103); until then a Release build says it has no server key and trusts no pack.
- **Production upgrade:** a paid Apple developer team, App Attest at enrollment, and device management
  (MDM). Free signing, used for this prototype, also expires every 7 days, which a field deployment
  cannot accept.
- Devices, codes and sequence numbers live in the directory database (#88). A code is deleted as it is
  read and a sequence number is raised in one UPDATE, so neither can pass twice even when requests race.

## Which model may run (signed model)
- The on-device model is signed with **OpenSSF Model Signing** (the official `model-signing` tool, pinned). The
  signature lists the SHA-256 of all 9 model files and is signed with our own P-256 key.
- The app checks it with CryptoKit **before importing and again before every load**: one changed byte, an extra or
  missing file, a symlink, another key or a file name that climbs out of the folder is refused. The public key is
  pinned in the app. Measured on the iPhone, offline: **0.37 to 0.59 s** for the 633 MB model.
- The app's parts list ([`docs/sbom/app.cdx.json`](sbom/app.cdx.json), CycloneDX) records the model's source,
  revision, hash and license, and the pinned database libraries. A check on every commit fails if it drifts
  from the signature or the pinned versions. CI also builds the backend's parts list from its lockfile.
- Details and how to verify it yourself: [docs/models/README.md](models/README.md).

## Lost, seized or forced to unlock (ADR 0012)
- **Least data:** the phone holds only active missions; each is purged after the server confirms it plus
  the retention time (30 days, set by the organization).
- **Keys that expire on their own:** a mission key works offline for **14 days** (set by the
  organization, up to 30), renewed by every sync. When the lease ends, or the clock is set back, the
  mission is crypto-shredded. A lost phone protects itself without anyone acting.
- **Shred order:** when the organization revokes a phone, its next genuine request gets a server-signed
  order to destroy every mission (`backend/tests/unit/test_shred_order.py`). Anyone else asking learns
  nothing.
- **Visible shred, no secret wipe:** the officer can destroy a mission (the organization can turn this off);
  it is confirmed, recorded and reported. There is **no hidden duress PIN**: in 2025 a traveller was
  prosecuted for wiping a phone that way during a border search.
- **If someone forces you to unlock:** your safety comes first. Unlock it, do not resist, tell your manager
  when safe; they revoke the phone and the shred order does the rest (staff card in ADR 0012).
- Every data item, where it lives and how it ends: [data-handling.md](data-handling.md).

## App lock (built, #73; checked on the iPhone)
- **When it asks:** on every cold start, and when the app comes back after **2 minutes** away (the
  organization sets 0 to 5). A clock that moved backwards while away also asks. The timing rule is code
  with its own tests (`ios/MissionCopilot/Platform/AppLock.swift`).
- **What it guards is the key, not the screen.** The database key is kept in the Keychain so that iOS
  releases it **only after Face ID or the passcode**, and **only while the phone has a passcode**, on this
  phone only. A lock that just asks Face ID "yes or no" can be bypassed on a tampered phone; this one
  cannot open the database without the key. Removing the phone's passcode deletes the key, so a phone
  without a passcode cannot open mission data at all.
- **The app switcher shows a cover**, not the last screen, whenever the app is not in front.
- **Limit:** once unlocked, the app can show the active missions to whoever holds the phone; that is why
  only active missions are on it and keys expire (ADR 0012).

## Mission packs (signed, #89)
- Before going offline the phone downloads its mission's **pack**: a manifest listing every file by SHA-256,
  size and type, the version, the expiry and the key id, plus the files themselves.
- The server signs the manifest's exact bytes with its P-256 key and a **pack label**, so a pack signature can
  never pass as a shred order. The phone pins the server's public key (#90) and checks the signature before it
  reads anything, then checks the rules again, the mission it asked for, the expiry and that the version is
  above the last one it accepted, so a genuine older pack played back is refused (#91).
- **The phone downloads in pieces**, each its own freshly signed request, and keeps a file only if its SHA-256
  matches. A lost signal or the system taking the time back pauses the download; the next run goes on from
  the bytes on the phone. It can go on outside the app (iOS 26 continued processing), but never in a
  background session, which would send old signed requests again.
- **While it downloads**, a pack waits in its own folder, never backed up, protected until first unlock so it
  can go on while the phone is locked. Once the pack is in the encrypted store, that folder is deleted (#92);
  one left behind is removed the next time the mission list opens.
- **Into the store** (#92): every section is checked against the contract's schema and every file hashed
  again, then one transaction seals each file with the mission's key, keeps its lineage (pack id, version,
  the manifest's and the file's SHA-256), replaces the older pack, records the version and writes an audit
  event. A pack checked while the phone was locked waits and goes in at unlock.
- **Offline**, the mission list shows the last list the server gave (kept in the encrypted store) and the
  packs on the phone. A download stopped by a lost signal goes on by itself when the connection returns.
- Limits live in the contract: 64 files, 20 MiB a file, 50 MiB a pack, three fixed folders, no "..".
- Packs live in the organization's own database: only the mission's team can read them (row-level security),
  nothing published can be changed, and a mission's version only goes up by one, so an older pack can be
  refused. Downloads resume after a lost signal (byte ranges); every manifest download is in the audit log.
- Production would keep the signing key in an HSM or cloud KMS (Iteration 9).

## Site checklists (KoBo / XLSForm format, #93)
- A mission pack carries a site checklist in KoBoToolbox's flat JSON. An admin writes it as an XLSForm
  .xlsx; the backend converts it (pyxform's reader), refuses anything the app does not read, and checks
  it as the phone does before it can be published.
- A signed pack proves who sent the checklist, not that it is safe (threat T54), so the phone checks it
  again: the contract's columns, types and limits, then the form itself, refused with the row to fix.
- **Expressions are never run as code.** A parser of our own reads the ODK subset (references, and, or,
  comparisons, math, selected, count-selected, string-length, regex, if, coalesce, number, int, today),
  capped at 500 characters and 32 deep. A regex() pattern that could hang the phone (over 200
  characters, backreferences, lookbehind) refuses the form; every regex runs with a 50 ms budget.
- **A rule the app cannot read never blocks the form:** the question shows and is marked unchecked.
- English and French only, the two languages tested; more can be added later, each with its own tests.

## Check it yourself
The code is open source. The [spike report](spikes/03-encryption.md) shows how to copy the database off a phone
you own and try to read it with standard tools. The same check runs automatically in CI on the spike package
and in the app's tests, and was done on a copy from the iPhone ([store proof](store-proof.md)).

## What it does not protect against (honest limits)
- **An unlocked phone in the wrong hands.** While unlocked, the app can read its data, and so can whoever holds
  the phone. The app lock (above) closes the store again on lock and after the grace time. A forced unlock
  reveals the active missions; least data and expiring keys limit what that is.
- **A phone without a passcode.** iOS Data Protection needs one; with the app lock such a phone cannot open
  mission data at all.
- **A compromised or jailbroken phone**, or attacks on memory while the app is open.
- **A bad model we signed ourselves.** The signature proves the model is the one we checked, not that the upstream
  model is free of problems. The app never lets the model decide a fact or a flag (ADR 0005).
- **Losing unsynced data.** If the phone is lost before sync, that data is gone. This is deliberate: losing data
  is safer than leaking it.
- **Remote wipe while offline.** Not possible; real deployments should add device management (MDM).
- **The server.** Separate rules apply there (one database per organization); see ADR 0008. The backend's
  own protections (tokens, organization isolation, limits, headers, audit log) are listed in
  [backend/README.md](../backend/README.md), each with its test in the [threat model](threat-model.md).

## Status
- For a reviewer: a 10-minute path through all of this, with checks to run: [security-review.md](security-review.md).
- Mobile security self-assessment against OWASP MASVS v2.1, all 24 controls, each with its status and a
  count checked on every commit: [masvs.md](masvs.md).
- Feasibility proven on a real iPhone (October 31, 2026). The store, keys, evidence and app lock were built
  test-first in Phase 4 and proven on the iPhone (November 2, 2026); documents, speech and the model's checks
  are rebuilt in the app in Phase 6.
- **Not independently audited** and no bug bounty. Treat this as a portfolio project, not certified software.
