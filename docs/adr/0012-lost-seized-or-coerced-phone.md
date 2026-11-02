# ADR 0012: Lost, seized or coerced phone

- Status: accepted (Iteration 3, story #49; app lock and key lease built with the encrypted store in Phase 4)
- Date: 2026-11-01

## Context
Field officers carry confidential mission data on a phone, often offline for days, sometimes through
checkpoints. Three things can go wrong: the phone is **lost or stolen**, it is **seized**, or its owner is
**forced to unlock it**. ADR 0008 already makes data unreadable while the phone is locked, keeps keys on
this device only, and crypto-shreds a mission when the server confirms it. What it does not answer: what
happens to a phone that never comes back online, what the officer should do under pressure, and how the
organization reaches a phone it has revoked.

Two findings shaped this decision (research for #49):
- A hidden "duress PIN" that wipes the phone can hurt the person it is meant to protect: in 2025 a US
  traveller was charged federally for wiping his phone with one during a border search, and press-freedom
  groups note that freshly wiped devices draw suspicion.
- An app lock that only checks a Face ID yes/no can be bypassed on a tampered phone. The lock must release
  the data key, not just hide the screen.

## Options
1. **Rely on iOS alone** (device passcode, Data Protection) and remote wipe through device management.
   Simple, but a phone that stays offline is never wiped, and the app holds data for as long as it likes.
2. **Hidden duress PIN** that silently wipes the app. Feels strong, but puts staff at legal and physical risk
   and looks like destruction of evidence.
3. **Least data, keys that expire on their own, visible shred, shred order on next contact, and an app lock
   bound to the data key.** No secret tricks; the protection works even if the officer does nothing.

## Decision
Option 3.

1. **Least data first.** The phone holds only active missions. A mission is purged after the server
   confirms it, plus the retention time (ADR 0008 rule 7: default 30 days, set per organization).
2. **Key lease.** Each mission key works offline for a lease the organization sets: **default 14 days,
   maximum 30**. Every sync renews it. When the lease ends without a sync, the mission is crypto-shredded
   (ADR 0008): its key is destroyed, so its data is unreadable at once. Unsynced work is lost, on purpose.
   A clock set backwards by more than 5 minutes counts as an ended lease.
3. **Shred is visible, never hidden.** "Destroy this mission" asks the officer to confirm, is recorded on
   the phone, and is reported on the next sync. There is **no duress PIN and no fake wipe**. The
   organization can turn in-app shred off.
4. **Shred order on next contact.** When the organization revokes a phone (#46), the phone's next signed
   request gets a **server-signed shred order** listing its missions, and the phone destroys them. Unknown
   and pending phones still get the same refusal as before, so nothing is revealed.
5. **App lock bound to the data.** Face ID or the phone passcode is asked on open and after **2 minutes** in
   the background (the organization can set 0 to 5); a cold start always asks. The database key sits in the
   Keychain behind user presence and is available **only while the phone has a passcode**, so the lock
   releases the key instead of hiding a screen, and a phone without a passcode cannot open mission data.
   The app switcher snapshot is covered.
6. **Coercion: safety first.** The staff card below is part of onboarding.

### Staff card: if someone forces you to unlock
- Your safety comes first. Do not resist, argue or hide the phone. Unlock it if you are forced to.
- Do not try to wipe the phone in front of anyone. The app has no secret wipe, on purpose.
- Mission data is encrypted per mission and expires on its own after the lease.
- As soon as you are safe, tell your manager. They revoke the phone; the next time it connects, it
  receives a shred order. Nothing else is expected of you.

## Why
- Least data and expiring keys protect a lost or seized phone **without anyone acting**, which is the only
  protection that works offline and under pressure.
- A visible, recorded shred keeps the organization honest about what was destroyed and when, and keeps the
  officer out of an "evidence destruction" situation.
- The shred order reuses device revocation (#46) and request signing, so no new channel is needed.
- Binding the lock to the Keychain key is what OWASP MASVS asks for authentication on the device: the data,
  not the screen, is protected.

## Consequences
- **A phone that is never seen again** keeps its encrypted data until the lease ends; the key expires, not
  the data. Offline there is no remote wipe; device management (MDM) can add it in a real deployment.
- **Work not synced within the lease is lost.** Officers must sync at least every 14 days on long trips;
  the app shows the days left.
- **A forced unlock reveals the active missions.** Least data limits what is on the phone; it cannot make
  an unlocked phone safe. This is stated in docs/security.md.
- **The lease trusts the phone's clock** within limits: moving it back is caught, moving it forward only
  shreds sooner.
- **More to build:** the lease, shred record and app lock arrive with the encrypted store in Phase 4; the
  phone side of the shred order with sync in Phase 8.

## Revisit when
- An organization uses device management (MDM): then remote wipe and passcode rules move there.
- An organization needs offline trips longer than 30 days.
- Legal advice for a specific country says otherwise about carrying or destroying data at borders.
