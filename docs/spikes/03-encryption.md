# Spike #16: encryption stack on device

Status: **GO**. All three layers of ADR 0008 work together on an iPhone 13 Pro Max (iOS 27.2, free Apple ID).
Raw data in results/encryption-iphone13promax.json. Code in `ios/AILab/EncryptionLab` (package, 30 tests) and
the AI Lab "Encryption proofs (#16)" screen.

## Setup
- **Database:** GRDB 7.11.1 fork ([lubobali/GRDB.swift](https://github.com/lubobali/GRDB.swift), branch
  `sqlcipher-7.11.1`, commit `b860da4a`) with SQLCipher.swift **exact 4.20.0**. Only `Package.swift` changes,
  following the author's own `GRDB+SQLCipher` comments. GRDB's 29 encryption tests pass on the fork.
  WAL mode (`DatabasePool`). Raw 32-byte key (`x'…'`), checked at open time.
- **Database key:** 32 random bytes in the Keychain, `WhenUnlockedThisDeviceOnly`, not synchronizable.
- **Files:** entitlement `default-data-protection = NSFileProtectionComplete`; per-user folder
  `Application Support/<user>/` created Complete and excluded from backup; user names that could leave the
  folder (`..`, `/`) are rejected.
- **Mission keys:** one random AES-256 key per mission, stored only wrapped with HPKE
  `P256_SHA256_AES_GCM_256`, bound to the mission id. One Secure Enclave key per mission, created with
  `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage` (Apple's default is weaker). Notes are AES-GCM sealed
  with the mission key before they reach the database.
- **Crypto-shred:** delete the mission's Secure Enclave key. The sealed rows stay until a later purge, so the
  proof is the cryptography, not a delete.

## Results on the iPhone
| Check | Result |
|---|---|
| SQLCipher linked | `4.20.0 community`; exactly one SQLite in the app (SQLCipher.framework) |
| Wrong database key | **rejected**: "file is not a database" |
| db, -wal, -shm protection | **Complete** (all three); folder excluded from backup |
| Crypto-shred | shredded mission: 1 sealed note left, **cannot be read**; other mission still readable |
| Phone locked (data locked 12.1 s after tap) | raw file, Keychain key, chip unwrap, database read: **all blocked** |
| Speed, 5000 inserts (median of 5) | plain **50.6 ms**, SQLCipher **50.7 ms**: no measurable cost |
| Chip unwrap | **5.0 ms** per mission open (software key: 0.13 ms) |

## Outside check: repeat it yourself
An attacker with a copy of the files, on a Mac:

```bash
# copy the files off a phone you own (app container, phone unlocked)
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.lubobali.missioncopilot.ailab \
  --source "Library/Application Support/amina/user.sqlite" --destination user.sqlite
# (same for user.sqlite-wal, user.sqlite-shm and Documents/plain-twin.sqlite)

sqlite3 "file:plain-twin.sqlite?immutable=1" "SELECT id, title FROM mission"   # kandor-roads|Kandor rural roads
sqlite3 "file:user.sqlite?immutable=1" "SELECT id, title FROM mission"         # file is not a database (26)
cat user.sqlite user.sqlite-wal user.sqlite-shm | LC_ALL=C grep -c -a Kandor    # 0
head -c 15 user.sqlite | xxd -p                                                  # random bytes, no SQLite header
```

The plain twin has the same schema and title, without SQLCipher. Its file starts with `SQLite format 3` and
shows "Kandor"; the real database shows nothing, not even table names. The same check runs in CI on the
Simulator (`OutsideCheckTests`).

## What the phone taught us (tests that were wrong, not the system)
1. **The first lock test was invalid, not failed.** It waited a guessed 20 s and ran while the phone was still
   unlocked (`protected data available = true`), so everything read. Now the test waits for iOS to lock the
   data, records when, and reports "not valid" instead of a false FAIL.
2. **A locked app gets about 30 s.** The second run outlived it and iOS killed the app before it saved.
3. **Complete protection blocked the app's own results file** while locked. That is the design working; the
   results now save on unlock.
4. **The first speed run said encryption was faster than no encryption** (16.7 vs 27.1 ms): warm-up noise.
   Now 5 rounds, order swapped each round, median, every round listed.

## Also learned
- **Free Apple ID signing keeps the Data Protection entitlement** (checked in the signed app and its profile).
- **The Secure Enclave is available on the Simulator on Apple Silicon** (it uses the Mac's), so chip tests run
  on the Mac; machines without one skip them with the reason.
- **Bare package tests get no Keychain** (`-34018`): Keychain tests run in a tiny ad-hoc signed host app.
  Unsigned (`CODE_SIGNING_ALLOWED=NO`) loses the Keychain too, so CI signs ad-hoc.
- **The Simulator has no Data Protection** (protection reads `nil`): that test is device-only, with the reason.
- **A chip key's access setting cannot be read back.** A weaker setting passed every test (mutation check), so
  it is one pinned value with a guard test, and the phone lock test proves the behaviour.
- **CryptoKit Secure Enclave keys are not stored in the chip:** the chip returns an encrypted blob only it can
  use, which we keep in the Keychain. Shred deletes that blob; any copy left is useless off this phone.

## Decision
- **GO on ADR 0008 as written.** Phase 3 rebuilds this test-first in the main app (fork, keys, folder, vault
  protocol) and adds the app lock (Face ID or passcode).
- Every security property has a test that was seen failing on purpose (mutation check), or a device proof
  where the Simulator cannot show it.
- User-facing summary: [security.md](../security.md).
