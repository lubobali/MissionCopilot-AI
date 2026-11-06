# Data handling sheet

One page for a security or privacy review: every piece of data, where it lives, how long, how it is
protected, who can see it and how it ends. It covers every item in the [data map](data-classification.md)
(a check fails if one is missing). Keys and labels: [ADR 0008](adr/0008-data-storage-isolation-encryption.md);
lost, seized or coerced phones: [ADR 0012](adr/0012-lost-seized-or-coerced-phone.md).

**Phone** = the officer's iPhone, encrypted store (file protection Complete + database key **DK** + mission
key **MK**). **Org database** = the organization's own database, one per organization, encrypted with its
key **TK**, hosted where the organization chooses. Nobody outside the organization, including the
developer, can read either. **Lease** = a mission key works offline for 14 days (set by the organization,
up to 30); every sync renews it. **Retention** = after the server confirms a mission, the phone keeps it
30 days (set by the organization). **Directory** = the server's one shared database for what must be
found before the organization is known (phones, enrollment codes, the audit log); it holds ids, never
mission data.

**Today's server (the demo, #103):** TK is planned (ADR 0008 rule 3), not built yet, so on the demo
server the databases sit unencrypted on its disk; only fictional data is there. The backups are
encrypted (restic). See [ADR 0013](adr/0013-hosting-on-a-shared-server.md) for when that changes.

| Data | Where it lives | How long | Encryption | Who can see it | Hosted | How it ends |
|---|---|---|---|---|---|---|
| Mission pack (budget, payments, milestones, last report, site checklist) | Phone (the newest pack only: a newer one replaces it in one transaction); org database (each version kept, never changed) | Phone: until retention or lease ends | DK + MK, every file sealed with MK and kept with its lineage (pack id, version, manifest and file SHA-256); TK; signed by the server | The mission's team only (row-level security) | Phone; org database | Crypto-shred on the phone; org records policy on the server |
| Mission list (mission ids, titles, pack versions and dates) | Phone (the last list the server gave); org database | Phone: replaced at every refresh, removed with the store | DK; TK | The officer; on the server the mission's team | Phone; org database | Replaced or removed with the store on the phone; org records policy |
| Mission pack while it downloads (half-done and checked files) | Phone only: a download folder inside the app, not the store, never backed up | Minutes: until the pack is in the store (#92); a stopped download keeps its bytes for the next run | iOS file protection until first unlock (a download goes on while the phone is locked); signed by the server, every file checked by SHA-256 before it is kept | The app only | Phone only | Deleted once imported into the store, or with the mission's folder; a wrong file is deleted at once |
| Voice debrief audio | Phone only | Until retention or lease ends | DK + MK | The officer only | Phone only, never uploaded | Crypto-shred |
| Debrief transcript and notes | Phone; org database inside an approved report | Phone: until retention or lease ends | DK + MK; TK | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Photo or scanned page (evidence) | Phone; org database after approval | Phone: until retention or lease ends; append-only (a retake adds a photo, the old one stays) | DK + MK (file and signed record both sealed), signed by the phone's chip key over hash, kind, time and location; TK. A site photo is taken with the camera only, never from the photo library, scaled to 2048 px and re-encoded, so the file holds no metadata (no place, maker or lens); the place is only in the signed record (#129) | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Extracted fact | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Risk flag | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team; integrity flags only the approver and managers | Phone; org database | Crypto-shred on the phone; org records policy |
| Report sentence | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Approval record | Phone; org database | Server: kept as a permanent record | DK + MK; TK, signed | The mission team and auditors | Phone; org database | Never changed or deleted on the server |
| Audit event | Phone; directory | Server: append-only, org records policy | DK + MK; hash-chained | Organization admins and auditors | Phone; directory | Never changed (the database refuses it); removed only by org records policy |
| Device signing key | Phone's Secure Enclave chip | Until the app is removed | Hardware, cannot be exported | Nobody, not even the officer | Phone only | Destroyed with the app; the phone is revoked on the server |
| Mission key | Phone's Keychain, wrapped by a chip key | Until retention or lease ends, a shred order, or the officer's shred | Secure Enclave | Nobody; it only unlocks its mission | Phone only | Destroyed: that mission becomes unreadable at once |
| Database key | Phone's Keychain, this device only | While the app is installed and the phone has a passcode | Hardware-backed Keychain; released only after Face ID or passcode | Nobody; released to the app after Face ID or passcode | Phone only | Deleted with the app or when the phone's passcode is removed |
| Device registration (public key, status) | Directory | Until an admin removes it; revoked stays revoked | Database access control | Organization admins | Directory | Removed by an admin; a revoked phone gets a shred order |
| Shred record (mission, reason, time) | Phone; org database after sync | Phone: until synced; server: with the audit log | DK; TK | Organization admins and auditors | Phone; org database | Kept as evidence of what was destroyed and when |
| Site checklist answers (and the finished walk, #129) | Phone; org database inside an approved report (Phase 8) | Phone: until retention or lease ends; once the walk is finished they cannot change (the store refuses) | DK + MK; TK | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; with its mission at a purge; org records policy |
| Agreed action checks (what was seen, a note, #129) | Phone; org database inside an approved report (Phase 8) | Phone: until retention or lease ends; locked when the walk is finished | DK + MK; TK | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; with its mission at a purge; org records policy |
| The officer's location at the sample point (a checklist answer, #129) | Phone, inside the sealed answer; org database inside an approved report | As the answer | DK + MK; TK | The officer; after approval, the mission team | Phone; org database | As the answer. Taken once, only when the officer taps Record location; never in the background, never tracked |
| Client IP address (audit log, server logs) | Directory: the `client` of an audit event (who asked, for refusals, limits, downloads, shred orders); the server's nginx access log and the API's log (address, time, path, answer) | Audit log: as long as the audit log (append-only, org records policy); nginx log: 14 days (rotated daily); API log: until 30 MB of newer lines replace it | In transit TLS; at rest not yet encrypted on the demo server (TK planned) | Audit log: organization admins and auditors; logs: the server's administrators | Directory; the server | Logs rotate out by themselves; audit rows only with the audit log, by org records policy |
| Server signing key | The server's secrets folder: one file, owned by the API's user, 0600; prod's spare key off the server | Until rotated (deploy/RUNBOOK.md) | File permissions only (a hardware key store is planned, ADR 0008) | The API process and the server's root; the spare's holder | The server | Replaced by a rotation; the app stops pinning the old key |
| Backups (every database, the roles, the server's secrets) | Each environment's own restic repository in a private bucket | 7 daily, 5 weekly, 6 monthly snapshots (about 6 months) | restic (AES-256, its own password) and the bucket's own encryption | Whoever holds the restic password: the server's root, and one copy off the server | The backup bucket's provider | restic forgets and prunes older snapshots; the bucket keeps only a file's last version |

**Not on this sheet because they are not data about anyone:** the on-device model (public, signed, see
[docs/models](models/README.md); it ships inside the app, read-only, and is checked before it is trusted)
and the fictional demo dataset.
