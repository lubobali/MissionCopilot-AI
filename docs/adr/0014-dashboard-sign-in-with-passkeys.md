# ADR 0014: Dashboard sign-in with passkeys

- Status: accepted (Iteration 8, story #174)
- Date: 2026-11-10

## Context
Phase 8 adds a manager dashboard in the browser (#175 to #178). The phone already proves who it is
with Secure Enclave signatures on every request (ADR 0008, `device_auth.py`) and the officer approves
each report with Face ID (#163). The managers need a sign-in of the same strength. The backend has
bearer-token routes but no token issuer, so they fail closed in production. A real deployment would
use the institution's single sign-on; the demo needs something real now, on the real domain.

## Options
1. **Passwords** with hashing: the weakest, phishable, and a password store to protect.
2. **A one-time code** from the operator for each sign-in: simple, but weak and slow to use.
3. **Passkeys (WebAuthn)**: Touch ID on the Mac, bound to the dashboard's origin, nothing secret on
   the server; a session cookie for the pages after sign-in.
4. **The institution's single sign-on (OIDC)**: right for a real deployment, not available here.

## Decision
Passkeys (option 3), on `py_webauthn` 3.0.1. The operator invites a manager with a one-time link
(`missioncopilot-admin invite-manager`, 15 minutes, used once); the manager registers a discoverable
passkey with user verification (Touch ID or the Mac's password), ES256 only, no attestation. Sign-in
asks for any of the site's passkeys; Endorse (#178) asks again with user verification required.
After sign-in the pages use a session cookie: `__Host-mc_session`, Secure, HttpOnly,
SameSite=Strict, 8 hours, stored on the server only as its SHA-256 and removed at sign-out. Every
dashboard POST must carry the dashboard's own Origin. The phone never uses cookies: it keeps signing
every request. People, invites, passkeys, challenges and sessions live in the directory database,
because sign-in happens before the organization is known.

## Why
- The officer signs with Face ID on the iPhone and the manager with Touch ID on the Mac: both people
  prove they were there, with keys that never leave their devices.
- Passkeys cannot be phished: the browser gives a passkey only to the origin it was made for.
- Nothing secret is kept on the server: public keys, digests of one-time codes and session tokens.
- Cookies only for pages, with OWASP's strongest settings plus the Origin check, close CSRF;
  SameSite=Strict alone is not counted on.

## Consequences
- The dashboard has its own Content Security Policy (this server only, no inline code); the API's
  `default-src 'none'` is unchanged.
- One first-party script is needed (`navigator.credentials` has no HTML form).
- A manager who loses their Mac is invited again; there is no password reset to attack.
- Passkeys need a real domain with https: the sign-in is proven on staging, not on a laptop.
- Without a Touch ID (a closed lid, an old Mac) the Mac asks its password instead (user
  verification still holds).

## Revisit when
- The institution's single sign-on is available: sign in through it, and keep passkeys for Endorse.
- More than one organization's managers use the same dashboard at once.
