# OWASP MASVS v2.1 matrix

Every control of the [OWASP Mobile Application Security Verification Standard](https://mas.owasp.org/MASVS/)
v2.1.0 (January 2024, 24 controls in 8 groups, including PRIVACY), with its official wording and an
honest status for the iPhone app. A check on every commit (`scripts/check_masvs.py`) fails if a control
is missing or reworded, or if a claim is not backed:

- **built**: in the main app or the backend, with tests (the file named).
- **spike**: proven in a lab on the real iPhone (the proof named), rebuilt test-first in the app later.
- **planned**: decided, with the phase or issue that builds it.
- **accepted**: a known limit of this prototype, with the reason. **not applicable**: with the reason.

This is a self-assessment, **not an independent audit**. Threat by threat: [threat-model.md](threat-model.md).

| Control | Requirement | Status | Proof, plan or reason |
|---|---|---|---|
| MASVS-STORAGE-1 | The app securely stores sensitive data. | spike | Encrypted store per user (SQLCipher), one key per mission wrapped by the Secure Enclave, files unreadable while locked: `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/EncryptedDatabaseTests.swift`; rebuilt in the app in Phase 4 |
| MASVS-STORAGE-2 | The app prevents leakage of sensitive data. | spike | Store and models excluded from backups, keys this device only, file sharing in Debug builds only: `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/ProtectedDirectoryTests.swift`, `ios/Config/Info-Debug.plist`; app switcher cover in Phase 4 |
| MASVS-CRYPTO-1 | The app employs current strong cryptography and uses it according to industry best practices. | built | Platform crypto only (CryptoKit, Python cryptography): P-256 ECDSA, AES-GCM, HPKE, SHA-256; no home-made crypto. Model signature check in the app: `ios/MissionCopilotTests/ModelSignatureTests.swift`; request signatures: `backend/tests/unit/test_device_requests.py` |
| MASVS-CRYPTO-2 | The app performs key management according to industry best practices. | spike | Keys born in the Secure Enclave or Keychain, this device only, never exported; mission keys expire on a lease and are crypto-shredded: `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/KeyLeaseTests.swift`, `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/MissionKeysTests.swift`; rebuilt in Phase 4 |
| MASVS-AUTH-1 | The app uses secure authentication and authorization protocols and follows the relevant best practices. | built | Server side: ES256 tokens for people, Secure Enclave request signatures for phones (no token on the phone), roles and organization only from the token, revoked phones get a signed shred order: `backend/tests/unit/test_auth.py`, `backend/tests/unit/test_shred_order.py`. Phone side of signing arrives with sync in Phase 8 |
| MASVS-AUTH-2 | The app performs local authentication securely according to the platform best practices. | planned | The lock releases the database key through the Keychain (user presence, passcode required), not a yes/no check; timing rule and key access are pinned in `ios/MissionCopilotTests/AppLockTests.swift`; the Face ID flow is built with the store in Phase 4 |
| MASVS-AUTH-3 | The app secures sensitive operations with additional authentication. | planned | Approving a report and destroying a mission ask for Face ID or the passcode again, and approval is signed by the Secure Enclave; Phase 6 |
| MASVS-NETWORK-1 | The app secures all network traffic according to the current best practices. | planned | iOS App Transport Security (TLS only, no exceptions); the server sends HSTS and refuses unknown hosts (`backend/tests/unit/test_browser_and_hosts.py`); phone networking arrives with sync in Phase 8 |
| MASVS-NETWORK-2 | The app performs identity pinning for all remote endpoints under the developer's control. | planned | Pin the organization's server key for shred orders (#60) and the TLS key for sync; Phase 8 |
| MASVS-PLATFORM-1 | The app uses IPC mechanisms securely. | not applicable | The app has no URL schemes, app extensions, shared app groups or clipboard use; revisit if any is added |
| MASVS-PLATFORM-2 | The app uses WebViews securely. | not applicable | The app has no WebViews; every screen is native SwiftUI |
| MASVS-PLATFORM-3 | The app uses the user interface securely. | planned | App switcher cover, no mission content in notifications, no sensitive text left on screen after the lock; designed in docs/security.md, built in Phase 4 |
| MASVS-CODE-1 | The app requires an up-to-date platform version. | planned | Today the minimum is iOS 18; document reading needs iOS 26, so the minimum is raised to iOS 26 in Phase 4 (#61) |
| MASVS-CODE-2 | The app has a mechanism for enforcing app updates. | planned | The server refuses requests from app versions below a minimum and the app asks to update; Phase 8 |
| MASVS-CODE-3 | The app only uses software components without known vulnerabilities. | built | Pinned dependencies, pip-audit on every pull request, Dependabot, CodeQL, a parts list (SBOM) checked against the pins: `.github/workflows/security.yml`, `scripts/test_check_bom.py`. Gap: Swift packages are pinned and listed but not scanned against an advisory database (#64) |
| MASVS-CODE-4 | The app validates and sanitizes all untrusted inputs. | built | Strict API input (unknown fields refused, size limits), model files checked by signature before use, scanned values checked against the bank's own records: `backend/tests/unit/test_errors_and_input.py`, `ios/MissionCopilotTests/ModelSignatureTests.swift`, `ios/AILab/DocumentLab/Tests/DocumentLabTests/FactChecksTests.swift` |
| MASVS-RESILIENCE-1 | The app validates the integrity of the platform. | accepted | Needs App Attest and device management (MDM), which need a paid Apple team; this prototype uses free signing. Stated as the production upgrade in ADR 0012 and docs/security.md |
| MASVS-RESILIENCE-2 | The app implements anti-tampering mechanisms. | accepted | The model is signature-checked before every load (built, `ios/MissionCopilotTests/ModelSignatureTests.swift`), but the app binary itself relies on iOS code signing; App Attest in production |
| MASVS-RESILIENCE-3 | The app implements anti-static analysis mechanisms. | accepted | No obfuscation on purpose: the code is open source and holds no secrets to hide; security rests on keys in the Secure Enclave, not on hidden code |
| MASVS-RESILIENCE-4 | The app implements anti-dynamic analysis techniques. | accepted | No debugger or jailbreak detection in the prototype; a compromised phone is out of scope (threat model T21); App Attest and MDM in production |
| MASVS-PRIVACY-1 | The app minimizes access to sensitive data and resources. | spike | Only active missions on the phone, keys that expire, voice audio never leaves the phone, AI runs on the phone; the app asks only for camera and microphone when used: `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/KeyLeaseTests.swift`, ADR 0012; rebuilt in Phase 4 |
| MASVS-PRIVACY-2 | The app prevents identification of the user. | accepted | Officers are identified on purpose: signed evidence needs it for accountability (ADR 0009), and the coercion trade-off is handled in ADR 0012. No analytics, advertising or tracking identifiers |
| MASVS-PRIVACY-3 | The app is transparent about data collection and usage. | planned | The data handling sheet (docs/data-handling.md) says what is kept, where, how long and who sees it; an in-app privacy screen and App Store privacy details follow in Phase 4 |
| MASVS-PRIVACY-4 | The app offers user control over their data. | spike | The officer can destroy a mission (the organization can turn this off), every shred is recorded and reported: `ios/AILab/EncryptionLab/Tests/EncryptionLabTests/KeyLeaseTests.swift`; rebuilt in Phase 4; access and deletion requests on the server in Phase 8 |

**Count:** 4 built, 5 spike, 8 planned, 5 accepted, 2 not applicable. The weakest group is RESILIENCE:
it needs a paid Apple team (App Attest) and device management, which a real deployment would add.
