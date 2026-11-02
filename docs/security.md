# How Mission Copilot protects field data

**Status: draft. Proven in a feasibility spike on an iPhone 13 Pro Max; not yet in the main app (rebuilt
test-first in Phase 4). Not independently audited.** Every threat and its status: [threat model](threat-model.md).
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
Every photo and scan is signed by the phone's Secure Enclave and linked to the item before it, with a signed
count and last link per mission. Changing one byte, removing an item or cutting off the last one is
detected offline, and the server verifies the phone's signatures with only the public key
([spike #17](spikes/04-signed-evidence.md)). Limit: on the phone alone, rolling back to an older chain needs
the server's sync receipt to be caught.

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
5. **A manager or admin can revoke a phone** at any time; its next request is refused.

**Limits (honest):**
- **Trust on first use.** Without Apple's App Attest the server cannot prove that the key really lives in
  a Secure Enclave, or that the request comes from our unmodified app. Enrollment is the control: a
  short-lived code for one named person, and a manager who approves each phone.
- **A stolen code** lets a thief enroll their own key, but only as a pending phone that a manager must
  approve. A code is shown once and expires in 15 minutes.
- **Production upgrade:** a paid Apple developer team, App Attest at enrollment, and device management
  (MDM). Free signing, used for this prototype, also expires every 7 days, which a field deployment
  cannot accept.
- Devices, codes and sequence numbers are kept in memory until the database arrives (Phase 5); there the
  sequence check becomes one transaction.

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

## App lock (designed; built with the encrypted store in Phase 4)
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

## Check it yourself
The code is open source. The [spike report](spikes/03-encryption.md) shows how to copy the database off a phone
you own and try to read it with standard tools. The same check runs automatically in CI on the spike package.

## What it does not protect against (honest limits)
- **An unlocked phone in the wrong hands.** While unlocked, the app can read its data, and so can whoever holds
  the phone. The app lock (above) is designed and its rules tested; it is built with the encrypted store in
  Phase 4. A forced unlock reveals the active missions; least data and expiring keys limit what that is.
- **A phone without a passcode.** iOS Data Protection needs one; with the app lock (Phase 4) such a phone
  cannot open mission data at all.
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
- Mobile security self-assessment against OWASP MASVS v2.1, all 24 controls: [masvs.md](masvs.md)
  (4 built, 5 spike, 8 planned, 5 accepted, 2 not applicable).
- Feasibility proven on a real iPhone (October 31, 2026); production code is rebuilt test-first in Phase 4.
- **Not independently audited** and no bug bounty. Treat this as a portfolio project, not certified software.
