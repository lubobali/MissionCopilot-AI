# Store proof on the iPhone (#74)

Status: **passed** on an iPhone 13 Pro Max (iOS 27.2, Debug build, Nov 2 2026). This is the main app's
Phase 4 store, not the spike: the real code, run on the phone, where the Simulator can't prove anything
because it does not enforce file protection or Keychain access rules. Raw data:
[store proof](spikes/results/store-proof-iphone13promax.json),
[lock test](spikes/results/store-lock-iphone13promax.json),
[signed chain](api/fixtures/evidence-chain-v2-iphone.json). Fictional data only (mission Kandor).

## How it runs
A Debug-only Lab screen ("Store proof (#74)") runs the proof on its own folder and its own keys, so it never
touches a real user's data. One Face ID, then two parts. Code: `ios/MissionCopilot/Lab/StoreProof.swift`,
`StoreLockTest.swift`, tested on the Simulator first (`StoreProofTests`, `StoreLockTestTests`).

## 1. Store proof: 9 of 9
| Check | Result on the iPhone |
|---|---|
| Encrypted store | SQLCipher 4.20.0, 8 migrations, another key refused |
| File protection | store.sqlite, -wal and -shm all **Complete** |
| Evidence chain | 3 photos signed by the Secure Enclave, chain valid |
| Trace | 1 fact pointing to evidence 1 and 2 |
| Sealed rows | 9 sealed fields, 0 with plain text |
| Lease ended | a mission created 15 days ago is shredded on open and unreadable; the other is kept |
| Shred order | the shredded mission is unreadable |
| Audit log | hash chain valid, 9 events |
| Export | the signed chain and the database copied out for the Mac |

## 2. Lock test: 4 of 4
The app adds a note every half second while the phone is locked for about 110 seconds, then unlocked.

| Time | What happened |
|---|---|
| 17.5 s | phone locking: protected data going away, app left the screen |
| 17.7 s | store paused: writes **and reads** refused as "suspended" |
| 27.7 s | the database file itself unreadable (iOS takes it about 10 s after the lock) |
| 126.6 s | unlocked: store resumed |

56 notes written, 58 refused while locked, nothing lost (136 notes, 136 expected), audit log valid, and no
crash report from the phone.

## 3. On the Mac
- The phone's chip-signed chain verifies in the Python server code, and one changed byte in any item breaks
  it (`backend/tests/unit/test_evidence_v2.py`).
- `sqlite3` cannot open the database copied off the phone ("file is not a database"), and the proof's marker
  text appears nowhere in its bytes.

## Bugs the phone found (the Simulator hid both)
1. **Chip keys never worked on a real phone.** The Keychain item that holds a Secure Enclave key's blob was
   saved with the chip-only rule (`.privateKeyUsage`), which a plain Keychain item can't use: error -25293.
   Mission keys (#70) and chip signing (#71) failed on the iPhone while every Simulator test passed. Now the
   chip key keeps that rule and its blob gets a plain one; a test pins the split, and the chip tests pass on
   the phone.
2. **A read while locked crashed the app.** The pause stopped writes only (GRDB's design). A read still maps
   the -shm file, which a locked phone makes unreadable, so iOS killed the app (SIGBUS, "protection class does
   not allow pagein"). Now every read goes through one door that pauses at the same signals, and the database
   pool is private so nothing can skip it. Found by the lock test, fixed test-first, then the lock test passed.

Also fixed on the way: the pause signal is app-wide, so a test that fakes a lock could pause another test
suite's store. Those suites now take turns.

## Limits
- One phone, one iOS version, a Debug build.
- The lock test locks for about 110 seconds. It does not prove what happens after hours in the background.
- Not independently audited.
