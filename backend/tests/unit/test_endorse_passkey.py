"""Endorse with the passkey (#178, step 8.8.2): the challenge names the manager and the exact report
(mission, version, approval hash), works once, needs user verification (Touch ID), and only the
same manager's own passkey answers it. The assertion comes back as it came, to be kept."""

import json

import pytest

from missioncopilot_backend.passkeys import (
    PasskeyRefused,
    endorse_options,
    registration_options,
    verify_endorsement,
    verify_registration,
)
from tests.unit.soft_authenticator import UP, SoftAuthenticator, unb64url
from tests.unit.test_passkeys import SITE, world  # noqa: F401 - the fixture

pytestmark = pytest.mark.unit

SUBJECT = "mission-1:1:" + "a" * 64


def manager(store, name="manager-1"):
    user = store.add_user("org-a", name, name, ("manager",))
    code, _ = store.issue_invite(user.id)
    key = SoftAuthenticator(SITE.rp_id, SITE.origin)
    verify_registration(store, key.create(registration_options(store, code, SITE)), SITE)
    return user, key


def test_the_endorse_options_need_user_verification(world):  # noqa: F811
    store = world[0]
    user, _ = manager(store)

    options = json.loads(endorse_options(store, SITE, user, SUBJECT))

    assert options["userVerification"] == "required" and options["rpId"] == SITE.rp_id


def test_the_managers_touch_id_endorses_and_the_assertion_is_kept(world):  # noqa: F811
    store = world[0]
    user, key = manager(store)
    credential = key.get(endorse_options(store, SITE, user, SUBJECT))

    kept = verify_endorsement(store, credential, SITE, user, SUBJECT)

    assert kept.credential_id == unb64url(credential["rawId"])
    assert kept.signature == unb64url(credential["response"]["signature"])
    assert json.loads(kept.client_data)["type"] == "webauthn.get"
    with pytest.raises(PasskeyRefused):
        verify_endorsement(store, credential, SITE, user, SUBJECT)  # works once


def test_without_user_verification_nothing_is_endorsed(world):  # noqa: F811
    store = world[0]
    user, key = manager(store)
    credential = key.get(endorse_options(store, SITE, user, SUBJECT), flags=UP)

    with pytest.raises(PasskeyRefused):
        verify_endorsement(store, credential, SITE, user, SUBJECT)


def test_a_challenge_for_another_report_or_manager_endorses_nothing(world):  # noqa: F811
    store = world[0]
    user, key = manager(store)
    other, other_key = manager(store, "manager-2")

    for_another = key.get(endorse_options(store, SITE, user, "mission-1:2:" + "a" * 64))
    with pytest.raises(PasskeyRefused):
        verify_endorsement(store, for_another, SITE, user, SUBJECT)
    made_for_other = key.get(endorse_options(store, SITE, other, SUBJECT))
    with pytest.raises(PasskeyRefused):
        verify_endorsement(store, made_for_other, SITE, user, SUBJECT)
    with_other_key = other_key.get(endorse_options(store, SITE, user, SUBJECT))
    with pytest.raises(PasskeyRefused):
        verify_endorsement(store, with_other_key, SITE, user, SUBJECT)
