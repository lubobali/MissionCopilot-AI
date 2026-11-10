"""The dashboard's people, invites, passkeys, challenges and sessions (#174, step 8.4.1): the same
contract on the in-memory stand-in and on the directory database. Codes, challenges and session
tokens work once or until they expire; only their SHA-256 is stored; a passkey's sign count only
rises."""

from collections.abc import Iterator

import psycopg
import pytest

from missioncopilot_backend.dashboard_auth import (
    CHALLENGE_SECONDS,
    INVITE_SECONDS,
    SESSION_SECONDS,
    DashboardMemory,
    DashboardStore,
)
from missioncopilot_backend.db.directory import Directory
from tests.db.postgres import throwaway_database

pytestmark = pytest.mark.db


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture(params=["memory", "postgres"])
def world(request) -> Iterator[tuple[DashboardStore, Clock, str | None]]:
    clock = Clock()
    if request.param == "memory":
        yield DashboardMemory(clock=clock), clock, None
        return
    with throwaway_database() as url, Directory.open(url, clock=clock) as directory:
        directory.add_organization("org-a", database="mc_org_a")
        yield directory.dashboard, clock, url


def test_a_manager_is_added_once(world):
    store, _, _ = world

    first = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))
    again = store.add_user("org-a", "manager-1", "Amina Diallo", ("manager",))

    assert first == again and store.user(first.id) == first
    assert (first.org_id, first.user_id, first.name, first.roles) == (
        "org-a", "manager-1", "Amina Diallo", ("manager",),
    )  # fmt: skip


def test_an_invite_works_once_and_expires(world):
    store, clock, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    code, expires = store.issue_invite(user.id)
    late, _ = store.issue_invite(user.id)

    assert expires == clock.now + INVITE_SECONDS
    assert store.consume_invite(code) == user
    assert store.consume_invite(code) is None, "once"
    clock.now += INVITE_SECONDS
    assert store.consume_invite(late) is None, "expired"
    assert store.consume_invite("not-a-code") is None


def test_a_challenge_works_once_for_its_purpose(world):
    store, clock, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    register = store.new_challenge("register", user.id)
    sign_in = store.new_challenge("sign_in", None)
    old = store.new_challenge("sign_in", None)

    assert len(register) == 32
    assert store.take_challenge(register, "sign_in") is None, "another purpose"
    assert store.take_challenge(register, "register") is None, "a wrong try uses it up"
    assert store.take_challenge(sign_in, "sign_in") is not None
    assert store.take_challenge(sign_in, "sign_in") is None, "once"
    clock.now += CHALLENGE_SECONDS
    assert store.take_challenge(old, "sign_in") is None, "expired"


def test_a_challenge_remembers_who_it_was_for(world):
    store, _, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))

    taken = store.take_challenge(store.new_challenge("register", user.id), "register")

    assert taken is not None and taken.user_id == user.id


def test_a_passkeys_sign_count_only_rises(world):
    store, _, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    store.add_passkey(user.id, b"cred-1", b"cose-key", 0)

    assert store.passkey(b"cred-1") is not None
    assert store.raise_sign_count(b"cred-1", 5) is True
    assert store.raise_sign_count(b"cred-1", 5) is False, "not higher"
    assert store.raise_sign_count(b"cred-1", 3) is False, "lower: a cloned key"
    found = store.passkey(b"cred-1")
    assert found is not None and found.sign_count == 5 and found.user_id == user.id
    assert [p.credential_id for p in store.passkeys_of(user.id)] == [b"cred-1"]


def test_a_count_of_zero_stays_zero_for_keys_that_do_not_count(world):
    """Apple's passkeys always send 0: the spec allows it, so 0 then 0 is fine."""
    store, _, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    store.add_passkey(user.id, b"cred-1", b"cose-key", 0)

    assert store.raise_sign_count(b"cred-1", 0) is True


def test_a_session_lasts_until_it_expires_or_ends(world):
    store, clock, _ = world
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    token = store.new_session(user.id)
    other = store.new_session(user.id)

    assert len(token) >= 43 and store.session(token) == user
    store.end_session(token)
    assert store.session(token) is None
    clock.now += SESSION_SECONDS
    assert store.session(other) is None, "expired"


def test_only_digests_are_stored(world):
    store, _, url = world
    if url is None:
        pytest.skip("the database's own rows")
    user = store.add_user("org-a", "manager-1", "Amina", ("manager",))
    code, _ = store.issue_invite(user.id)
    token = store.new_session(user.id)

    with psycopg.connect(url) as conn:
        rows = conn.execute(
            "SELECT digest FROM dashboard_invites UNION ALL SELECT digest FROM dashboard_sessions"
        ).fetchall()
    assert code not in str(rows) and token not in str(rows)
