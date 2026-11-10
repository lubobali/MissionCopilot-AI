"""Passkeys for the dashboard (#174, step 8.4.2), on py_webauthn. A manager registers from a one-
time invite: a discoverable passkey (no user name to type), user verification required (Touch ID or
the Mac's password), ES256 only, no attestation. Sign-in asks for any of the site's passkeys;
Endorse (#178) asks again with user verification required. Every challenge is the server's, works
once and for one purpose; the origin and the site id must be the dashboard's; a sign count that does
not rise (0 then 0 aside) is a cloned key. Every problem is the same PasskeyRefused: the caller
learns nothing."""

import base64
import binascii
import json
from dataclasses import dataclass
from typing import Any

from webauthn import (
    generate_authentication_options,
    generate_registration_options,
    options_to_json,
    verify_authentication_response,
    verify_registration_response,
)
from webauthn.helpers.cose import COSEAlgorithmIdentifier
from webauthn.helpers.exceptions import InvalidAuthenticationResponse, InvalidRegistrationResponse
from webauthn.helpers.structs import (
    AttestationConveyancePreference,
    AuthenticatorSelectionCriteria,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from missioncopilot_backend.dashboard_auth import DashboardStore, DashboardUser, Purpose

ES256 = [COSEAlgorithmIdentifier.ECDSA_SHA_256]


class PasskeyRefused(Exception):
    """Any problem with an invite, a challenge or a credential: one answer for all."""


@dataclass(frozen=True)
class Site:
    rp_id: str  # the dashboard's host name, e.g. mc.lubot.ai
    origin: str  # https://mc.lubot.ai
    name: str = "MissionCopilot"


def _bytes(text: object) -> bytes:
    if not isinstance(text, str):
        raise PasskeyRefused
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (binascii.Error, ValueError):
        raise PasskeyRefused from None


def _challenge(credential: object) -> bytes:
    """The challenge the browser signed, read from clientDataJSON before anything is verified."""
    if not isinstance(credential, dict) or not isinstance(credential.get("response"), dict):
        raise PasskeyRefused
    try:
        client = json.loads(_bytes(credential["response"].get("clientDataJSON")))
    except ValueError:
        raise PasskeyRefused from None
    if not isinstance(client, dict):
        raise PasskeyRefused
    return _bytes(client.get("challenge"))


def registration_options(store: DashboardStore, invite_code: str, site: Site) -> str:
    """Options for navigator.credentials.create(); the invite is used up here."""
    user = store.consume_invite(invite_code)
    if user is None:
        raise PasskeyRefused
    challenge = store.new_challenge("register", user.id)
    options = generate_registration_options(
        rp_id=site.rp_id, rp_name=site.name, user_name=user.user_id, user_display_name=user.name,
        user_id=user.id.encode(), challenge=challenge,
        attestation=AttestationConveyancePreference.NONE,
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
        exclude_credentials=[], supported_pub_key_algs=ES256,
    )  # fmt: skip
    return options_to_json(options)


def verify_registration(
    store: DashboardStore, credential: dict[str, Any], site: Site
) -> DashboardUser:
    challenge = store.take_challenge(_challenge(credential), "register")
    user = store.user(challenge.user_id) if challenge and challenge.user_id else None
    if challenge is None or user is None:
        raise PasskeyRefused
    try:
        verified = verify_registration_response(
            credential=credential, expected_challenge=_challenge(credential),
            expected_rp_id=site.rp_id, expected_origin=site.origin,
            require_user_verification=True, supported_pub_key_algs=ES256,
        )  # fmt: skip
    except (InvalidRegistrationResponse, ValueError, KeyError, TypeError):
        raise PasskeyRefused from None
    if store.passkey(verified.credential_id) is not None:
        raise PasskeyRefused
    store.add_passkey(user.id, verified.credential_id, verified.credential_public_key,
                      verified.sign_count)  # fmt: skip
    return user


def authentication_options(store: DashboardStore, site: Site, purpose: Purpose = "sign_in") -> str:
    """Options for navigator.credentials.get(): any of this site's passkeys (discoverable)."""
    challenge = store.new_challenge(purpose, None)
    needs = (
        UserVerificationRequirement.REQUIRED
        if purpose == "endorse"
        else UserVerificationRequirement.PREFERRED
    )
    options = generate_authentication_options(
        rp_id=site.rp_id, challenge=challenge, allow_credentials=[], user_verification=needs
    )
    return options_to_json(options)


def verify_authentication(
    store: DashboardStore,
    credential: dict[str, Any],
    site: Site,
    purpose: Purpose = "sign_in",
    require_uv: bool = False,
) -> DashboardUser:
    expected = _challenge(credential)
    if store.take_challenge(expected, purpose) is None:
        raise PasskeyRefused
    key = store.passkey(_bytes(credential.get("rawId")))
    user = store.user(key.user_id) if key else None
    if key is None or user is None:
        raise PasskeyRefused
    try:
        verified = verify_authentication_response(
            credential=credential, expected_challenge=expected, expected_rp_id=site.rp_id,
            expected_origin=site.origin, credential_public_key=key.public_key,
            credential_current_sign_count=key.sign_count, require_user_verification=require_uv,
        )  # fmt: skip
    except (InvalidAuthenticationResponse, ValueError, KeyError, TypeError):
        raise PasskeyRefused from None
    # The library already refuses a count that did not rise; this one UPDATE also closes the race of
    # two sign-ins with the same count at the same moment (only one can raise it).
    if not store.raise_sign_count(key.credential_id, verified.new_sign_count):
        raise PasskeyRefused
    return user
