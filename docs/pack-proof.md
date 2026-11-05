# Pack proof on the iPhone (#94)

Status: **passed** on an iPhone 13 Pro Max (iOS 27.2, the Staging build "MC Staging", Nov 4 to 5 2026),
against the real staging server `https://mc-staging.lubot.ai`, organization `kandor-e2e` (the demo
organization `kandor-works` and production were never touched). The last fix (a shredded mission taking a
new pack, 94.0h) was then checked on the phone on Nov 5: after the shred the iPhone connected again and the
roads mission took v9, "Ready for offline" (13 files, 15 MB, checklist 9 questions). Fictional data only
(mission Kandor).

This is what only the real phone can show: the Secure Enclave key end to end, a download that goes on
outside the app (BGContinuedProcessingTask), real networks (Wi-Fi, mobile data, IPv6 only), the phone lock,
and a revoke that destroys the missions. Every step was started from the Home Screen icon, not from Xcode,
so no debugger hid the background behaviour. For each step the server session posted its own nginx and API
log on #94; the phone's side comes from its own log (`os.Logger`, category `pack`, no personal data and no
file contents), collected with `log collect`. Screenshots were taken for each step and are kept private.

## The proof pack
The server published pack versions 2 to 9 for the roads mission, each signed with the staging key
`4bf338c69bae5bfa`: 13 files, about 15 MB. Twelve are the normal pack; the 13th is a clearly fictional file of
exactly 15,000,000 bytes, so a download takes 15 pieces of 1 MiB and a cut lands in the middle of a file.
Each new version changed one file only, so reuse and resume could be counted byte by byte.

## Results: 10 of 10 steps
| Step | What was done | Result on the iPhone | What the server saw |
|---|---|---|---|
| a | Connect with a one-time code | The chip key enrolled, "Waiting for approval", then "Connected and approved" | Device pending, then active |
| b | Wi-Fi (3G link profile), airplane mode half way, then off | "Update paused, waiting for connection", the old pack stays Ready; it went on by itself, with iOS's "Downloading mission pack" progress | All pieces 206; only the piece in transit at the cut asked again |
| c | Mobile data only (Wi-Fi off) | The list refreshed and the update downloaded | All 206 (this run found bug 5) |
| d | IPv6 only (the Mac's NAT64 network, mobile data off) | Connected again with a fresh chip key, 15 MB downloaded and verified | Enroll 201, 13 files once each, all 206 |
| e | Home gesture mid download, then lock the phone | Goes on outside the app; "Paused while the iPhone is locked"; back in the app it went on by itself | 9 min with nothing from the phone, then piece 7 onwards: exactly 15,000,000 bytes, no piece twice |
| f | The staging API restarted mid download | "The server is busy or restarting. It goes on by itself in 5 seconds."; finished, nothing tapped | One 503 (JSON, Retry-After) during the 1.5 s restart, the next piece 7 s later |
| g | The phone's clock set 10 minutes ahead | The list answered normally | 200; no `device_auth_failed` (the phone signs with the server's time) |
| h | The server's minimum app build raised above the phone's | "This app is too old for the server. Update the app; the missions on this iPhone stay as they are." | 403 `app_too_old`; nothing retried |
| i | Airplane mode, app closed and opened again | "No connection. Showing the missions from the last time this iPhone was online."; pack details work (v7, 13 files, checklist 9 questions in English and French) | Nothing (offline) |
| j | The phone revoked by the operator | The signed shred order checked and acted on: missions destroyed, the enrollment removed (after bug 8 was fixed) | 410 with the signed shred order |

## The cut, both sides (pack v7)
The phone's own log, collected from the iPhone (local times):
```
22:27:07.163 ask dcce1de2 bytes=12582912-13631487
22:27:08.617 stop dcce1de2 offline
22:27:13 … 22:27:51  run end paused(offline) ×6
22:28:16.811 run start version=7 files=13 reused=0 saved=12595588 total=15012676
22:28:16.865 ask dcce1de2 bytes=12582912-13631487
22:28:17.420 run end verified
```
The server (UTC): pieces 1 to 13 sent, 69 s with nothing, then piece 13 again, 14 and 15. Piece 13 was asked
and the cut came before it arrived (no `got` line), so nginx's "sent" was never received. The phone had
exactly 12 pieces saved and asked piece 13 again: nothing it had saved was fetched twice. The six
`paused(offline)` lines are its own tries while the network was not back yet (bug 6).

Reuse (pack v5, one 366-byte file changed): the phone's log says `reused=12`, it asked only
`bytes=0-365`, and the server saw one 206 of 366 bytes. The update cost about 2.9 KB instead of 15 MB.

## Bugs found (the Simulator and the local end to end hid them all)
Each was fixed test first and mutation checked, on branch `story/94-iphone-proof`.

1. **Connect and Missions opened blank** (f46b46d). An empty screen has no size, so its loading task never
   ran. Every screen now shows a loading line first. The screenshot test missed it: it gives each screen a
   phone-sized frame.
2. **Download crashed the app** (e873135). The background task's launch handler inherited the main actor,
   and the system calls it on a background queue (Swift 6 run time check). Now `@Sendable`.
3. **"Could not save the download"** (e873135). File paths were percent-encoded, and the iPhone's folder is
   "Application Support" (`Application%20Support` does not exist). Tests now use a folder with a space.
4. **Locking the phone mid download failed it** (154fbaf, found by reading the code before the run). The
   chip key and the request counter work only while unlocked, and that stays (it is the security). Now the
   download pauses and goes on after unlock.
5. **Every update fetched every file again** (34f2938). The phone reused only files left in its download
   folder, which is removed after import. Now an unchanged file (same SHA-256 in the signed manifest) is taken
   from the encrypted store and checked again.
6. **No retry after airplane mode** (8b88c4f). The app tried once the moment the network came back, before
   it was ready. Now an offline pause also tries again after 5, 10, 20, 40, 80 s.
7. **No resume when coming back within the lock's grace time** (d033a98). Coming back to the front while
   unlocked now does the same refresh as an unlock.
8. **A wrong clock made the phone refuse its genuine shred order** (6b5c680, security). The clock was still
   10 minutes ahead from step g. A thief could do the same on purpose. Now the order's age is judged by the
   server's time; proven on the iPhone with the clock still wrong (threat T69).
9. **A shredded phone could never connect again** (23fcda3). The shred kept the chip key, and the server never
   takes a known key, a revoked one included. Now a shred deletes the key and a new connection starts from a
   fresh one (threat T70).
10. **A shredded mission could not take a new pack** (3bfccc3). The store allowed one shred per mission ever,
    so reusing the mission would make its next shred fail, and the error showed as "locked". Now a mission has
    lives (schema v10, ADR 0008): the next life under a fresh key, the next shred destroys it again, the
    history stays. A store error that is not a lock now says "could not save" (threat T71). Proven on the
    iPhone: the shredded mission downloaded v9 again.
11. **After a shred the Missions screen stayed on "Loading missions"** (852a3af). Now the Missions and home
    screens say "Your organization disconnected this iPhone, so its N missions were destroyed. Ask your admin
    before connecting again."

## Seen, not fixed (small, written down)
- **The manifest is asked again on every list refresh**, even when the pack is complete: 7 times in 84 s
  after step d, each one a `pack_downloaded` audit row on the server. No file is fetched, so it costs little
  data, but it fills the audit log. Better: ask only when the list says a newer version exists (#121).
- In step e a second run started in the middle of the file (a refresh while one was going). No piece was
  repeated.
- Console's live view showed some log lines three times; the archived log has each line once.

## Limits
- One phone, one iOS version, the Staging build signed with a free developer team.
- The longest pause was about 9 minutes; it does not prove what happens after hours in the background.
- The IPv6-only network was the Mac's NAT64 test network, not a carrier's.
- Not independently audited.
