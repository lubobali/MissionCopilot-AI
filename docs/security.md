# How Mission Copilot protects field data

**Status: draft, proven in a feasibility spike on an iPhone 13 Pro Max. Not independently audited.**
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

## Check it yourself
The code is open source. The [spike report](spikes/03-encryption.md) shows how to copy the database off a phone
you own and try to read it with standard tools. The same check runs automatically in CI.

## What it does not protect against (honest limits)
- **An unlocked phone in the wrong hands.** While unlocked, the app can read its data, and so can whoever holds
  the phone. The app lock (Face ID or passcode on open, lock after inactivity) is planned for Phase 3.
- **A phone without a passcode.** iOS Data Protection needs one.
- **A compromised or jailbroken phone**, or attacks on memory while the app is open.
- **Losing unsynced data.** If the phone is lost before sync, that data is gone. This is deliberate: losing data
  is safer than leaking it.
- **Remote wipe while offline.** Not possible; real deployments should add device management (MDM).
- **The server.** Separate rules apply there (one database per organization); see ADR 0008.

## Status
- Feasibility proven on a real iPhone (October 31, 2026); production code is rebuilt test-first in Phase 3.
- **Not independently audited** and no bug bounty. Treat this as a portfolio project, not certified software.
