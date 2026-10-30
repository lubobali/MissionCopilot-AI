# ADR 0001: Native iOS app + Python backend

- Status: accepted
- Date: 2026-10-30

## Context
Field staff need AI that works with no internet: notes, document reading, report drafts.
That means a language model running on the phone itself, plus speech to text and
document text recognition. When they are back online, reports sync for approval.

## Options
1. PWA (web app installed on the home screen): one codebase for web and phone,
   easy to ship. But on-device models in the browser are slower and limited by memory,
   and background sync and speech are weaker on iOS.
2. Cross-platform (React Native / Flutter): one codebase for iOS and Android.
   But the on-device AI engines (llama.cpp, MLX) and Apple frameworks (Vision, Speech,
   Translation) are native, so we would write native bridges anyway.
3. Native iOS (Swift, SwiftUI): direct access to on-device AI engines, Apple Vision
   (document scanning, text recognition), file encryption and Keychain.
   iOS only.

## Decision
Native iOS app in Swift/SwiftUI for the field. Python (FastAPI) backend for sync,
approvals and the audit log. Web dashboard for managers.

## Why
- The core value (offline AI on the phone) depends on native engines and Apple frameworks.
- The step 0.0 bake-off on an iPhone 13 Pro Max showed a 1.2B model at about 38 tokens/sec
  with a native engine (see docs/bakeoff.md). That is fast enough for the field.
- iOS data protection and Keychain give strong on-device security for confidential notes.
- The backend is small and mostly online work, where Python is fast to build and test.

## Consequences
- iOS only for now. Android would need its own app or a shared core later.
- Two languages to maintain (Swift + Python), so the API contract (OpenAPI) is the
  single source of truth between them.
- Builds need a Mac with Xcode.

## Revisit when
- An organization needs Android at scale, or
- Browser on-device AI (WebGPU) becomes fast enough on older phones to make a PWA viable.
