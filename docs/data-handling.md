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
30 days (set by the organization).

| Data | Where it lives | How long | Encryption | Who can see it | Hosted | How it ends |
|---|---|---|---|---|---|---|
| Mission pack (budget, payments, milestones, last report) | Phone; org database | Phone: until retention or lease ends | DK + MK; TK | The mission's officer and manager | Phone; org database | Crypto-shred on the phone; org records policy on the server |
| Voice debrief audio | Phone only | Until retention or lease ends | DK + MK | The officer only | Phone only, never uploaded | Crypto-shred |
| Debrief transcript and notes | Phone; org database inside an approved report | Phone: until retention or lease ends | DK + MK; TK | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Photo or scanned page (evidence) | Phone; org database after approval | Phone: until retention or lease ends | DK + MK, signed by the phone's chip key; TK | The officer; after approval, the mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Extracted fact | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Risk flag | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team; integrity flags only the approver and managers | Phone; org database | Crypto-shred on the phone; org records policy |
| Report sentence | Phone; org database after approval | Phone: until retention or lease ends | DK + MK; TK | The mission team | Phone; org database | Crypto-shred on the phone; org records policy |
| Approval record | Phone; org database | Server: kept as a permanent record | DK + MK; TK, signed | The mission team and auditors | Phone; org database | Never changed or deleted on the server |
| Audit event | Phone; org database | Server: append-only, org records policy | DK + MK; TK, hash-chained | Organization admins and auditors | Phone; org database | Never changed; removed only by org records policy |
| Device signing key | Phone's Secure Enclave chip | Until the app is removed | Hardware, cannot be exported | Nobody, not even the officer | Phone only | Destroyed with the app; the phone is revoked on the server |
| Mission key | Phone's Keychain, wrapped by a chip key | Until retention or lease ends, a shred order, or the officer's shred | Secure Enclave | Nobody; it only unlocks its mission | Phone only | Destroyed: that mission becomes unreadable at once |
| Database key | Phone's Keychain, this device only | While the app is installed and the phone has a passcode | Hardware-backed Keychain; released only after Face ID or passcode | Nobody; released to the app after Face ID or passcode | Phone only | Deleted with the app or when the phone's passcode is removed |
| Device registration (public key, status) | Org database | Until an admin removes it; revoked stays revoked | TK | Organization admins | Org database | Removed by an admin; a revoked phone gets a shred order |
| Shred record (mission, reason, time) | Phone; org database after sync | Phone: until synced; server: with the audit log | DK; TK | Organization admins and auditors | Phone; org database | Kept as evidence of what was destroyed and when |

**Not on this sheet because they are not data about anyone:** the on-device model (public, signed, see
[docs/models](models/README.md)) and the fictional demo dataset.
