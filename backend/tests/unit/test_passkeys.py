"""Passkeys for the dashboard (#174, step 8.4.2): a manager registers from a one-time invite (a
discoverable passkey, user verification required, ES256 only) and signs in with it; every challenge
works once and for one purpose; the origin and the site must be the dashboard's; a sign count that
does not rise means a cloned key and is refused."""

import json
from typing import Any, cast

import pytest

from missioncopilot_backend.dashboard_auth import DashboardMemory
from missioncopilot_backend.passkeys import (
    PasskeyRefused,
    Site,
    authentication_options,
    registration_options,
    verify_authentication,
    verify_registration,
)
from tests.unit.soft_authenticator import UP, SoftAuthenticator

pytestmark = pytest.mark.unit

SITE = Site(rp_id="mc.example.org", origin="https://mc.example.org", name="MissionCopilot")


@pytest.fixture
def world():
    store = DashboardMemory()
    user = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    code, _ = store.issue_invite(user.id)
    return store, user, code, SoftAuthenticator(SITE.rp_id, SITE.origin)


def registered(world):
    store, user, code, key = world
    options = registration_options(store, code, SITE)
    assert verify_registration(store, key.create(options), SITE) == user
    return store, user, key


def test_the_invite_gives_options_for_a_discoverable_passkey_with_user_verification(world):
    store, user, code, _ = world

    options = json.loads(registration_options(store, code, SITE))

    assert options["rp"] == {"id": "mc.example.org", "name": "MissionCopilot"}
    assert (
        options["user"]["name"] == "manager-1" and options["user"]["displayName"] == "Amina Diallo"
    )
    assert options["authenticatorSelection"]["residentKey"] == "required"
    assert options["authenticatorSelection"]["userVerification"] == "required"
    assert [p["alg"] for p in options["pubKeyCredParams"]] == [-7], "ES256 only"
    with pytest.raises(PasskeyRefused):
        registration_options(store, code, SITE)  # the invite works once


def test_a_registered_passkey_is_kept(world):
    store, user, key = registered(world)

    kept = store.passkey(key.credential_id)
    assert kept is not None and kept.user_id == user.id


@pytest.mark.parametrize("problem", ["no user verification", "another origin", "replayed"])
def test_a_registration_is_refused_when(world, problem):
    store, _, code, key = world
    options = registration_options(store, code, SITE)
    if problem == "no user verification":
        credential = key.create(options, flags=UP)
    elif problem == "another origin":
        credential = key.create(options, origin="https://evil.example.org")
    else:
        credential = key.create(options)
        verify_registration(store, credential, SITE)

    with pytest.raises(PasskeyRefused):
        verify_registration(store, credential, SITE)


def test_the_same_key_cannot_be_registered_twice(world):
    store, user, key = registered(world)
    code, _ = store.issue_invite(user.id)

    with pytest.raises(PasskeyRefused):
        verify_registration(store, key.create(registration_options(store, code, SITE)), SITE)


def test_a_manager_signs_in_and_the_count_rises(world):
    store, user, key = registered(world)

    assert verify_authentication(store, key.get(authentication_options(store, SITE)), SITE) == user
    found = store.passkey(key.credential_id)
    assert found is not None and found.sign_count == 1


SIGN_IN_PROBLEMS = ["replayed", "cloned key", "unknown key", "another origin",
                    "endorse needs verification", "a sign-in challenge"]  # fmt: skip


@pytest.mark.parametrize("problem", SIGN_IN_PROBLEMS)
def test_a_sign_in_is_refused_when(world, problem):
    store, _, key = registered(world)
    purpose, needs_uv = "sign_in", False
    options = authentication_options(store, SITE)
    if problem == "replayed":
        credential = key.get(options)
        verify_authentication(store, credential, SITE)
    elif problem == "cloned key":
        verify_authentication(store, key.get(options, count=5), SITE)
        credential = key.get(authentication_options(store, SITE), count=3)
    elif problem == "unknown key":
        credential = SoftAuthenticator(SITE.rp_id, SITE.origin).get(options)
    elif problem == "another origin":
        credential = key.get(options, origin="https://evil.example.org")
    elif problem == "endorse needs verification":
        options = authentication_options(store, SITE, purpose="endorse")
        credential, purpose, needs_uv = key.get(options, flags=UP), "endorse", True
    else:
        credential, purpose = key.get(options), "endorse"  # a sign-in challenge used to endorse

    with pytest.raises(PasskeyRefused):
        verify_authentication(store, credential, SITE, purpose=purpose, require_uv=needs_uv)


def test_garbage_is_refused_not_an_error(world):
    store, _, _, _ = world

    for credential in (
        {},
        {"response": {}},
        "not json",
        {"id": "x", "response": {"clientDataJSON": "!!"}},
    ):
        with pytest.raises(PasskeyRefused):
            verify_authentication(store, cast(Any, credential), SITE)  # not a credential at all
