"""A manager's decision on a report (#178, steps 8.8.0-8.8.1): endorsed or sent back with a note,
one final decision per version, append-only, never by someone on the mission's own team (Postgres
refuses it). A report sent back comes again as the next version; one that was not cannot be sent
again. The officer's phone reads the decision on its next contact."""

import uuid
from collections.abc import Iterator

import psycopg
import pytest

from missioncopilot_backend.db.reviews import Assertion, Decided, NotAllowed, Reviews
from missioncopilot_backend.db.sync import AlreadyReceived, PostgresSync
from tests.db.dashboard_world import ROADS, DashboardWorld, dashboard_world, report_batch
from tests.unit.sync_batches import PhoneBatch

pytestmark = pytest.mark.db

HASH = "c" * 64
TOUCH = Assertion(b"cred", b"auth-data", b"client-data", b"sig")


@pytest.fixture
def world() -> Iterator[DashboardWorld]:
    yield from dashboard_world()


def send(world: DashboardWorld, draft: str) -> None:
    batch, _ = report_batch(PhoneBatch(ROADS, draft=draft))
    PostgresSync(world.pool).save("officer-7", ROADS, batch, device_id=str(uuid.uuid4()),
                                  approved_by="this-phone", approved_at=1_794_300_000.0,
                                  key=str(uuid.uuid4()), now=1_794_300_100.0)  # fmt: skip


def test_an_endorsement_is_kept_with_its_assertion(world):
    reviews = Reviews(world.pool)

    made = reviews.decide("manager-1", "Amina Diallo", ROADS, 1, "endorsed", None, HASH,
                          1_794_280_000.0, TOUCH)  # fmt: skip

    assert (made.version, made.decision, made.reviewer_name) == (1, "endorsed", "Amina Diallo")
    assert reviews.of(ROADS, "manager-1") == [made]
    with psycopg.connect(world.admin) as conn:
        row = conn.execute("SELECT credential_id, signature FROM report_reviews").fetchone()
    assert row is not None and (bytes(row[0]), bytes(row[1])) == (b"cred", b"sig")


def test_a_decision_is_final(world):
    reviews = Reviews(world.pool)
    reviews.decide("manager-1", "A", ROADS, 1, "sent_back", "Check the bridge numbers.", HASH, 1.0)

    with pytest.raises(Decided):
        reviews.decide("manager-2", "B", ROADS, 1, "endorsed", None, HASH, 2.0, TOUCH)
    with psycopg.connect(world.admin) as conn, pytest.raises(psycopg.errors.RaiseException):
        conn.execute("UPDATE report_reviews SET note = 'changed'")


def test_a_manager_on_the_missions_team_cannot_decide(world):
    reviews = Reviews(world.pool)

    assert reviews.on_team("officer-7", ROADS) and not reviews.on_team("manager-1", ROADS)
    with pytest.raises(NotAllowed):
        reviews.decide("officer-7", "Kofi", ROADS, 1, "endorsed", None, HASH, 1.0, TOUCH)


def test_an_endorsement_needs_its_assertion_and_a_send_back_its_note(world):
    reviews = Reviews(world.pool)

    with pytest.raises(ValueError):
        reviews.decide("manager-1", "A", ROADS, 1, "endorsed", None, HASH, 1.0)
    with pytest.raises(ValueError):
        reviews.decide("manager-1", "A", ROADS, 1, "sent_back", "", HASH, 1.0)


def test_a_report_sent_back_comes_again_as_the_next_version(world):
    with pytest.raises(AlreadyReceived):
        send(world, "draft-2")  # not sent back: the first report stands
    Reviews(world.pool).decide(
        "manager-1", "A", ROADS, 1, "sent_back", "Check the bridge.", HASH, 1.0
    )

    send(world, "draft-2")

    newest = PostgresSync(world.pool).report("officer-7", ROADS)
    assert newest is not None and (newest.version, newest.draft_id) == (2, "draft-2")
    assert len(newest.sentences) == 3


def test_the_phone_reads_the_newest_decision(world):
    sync = PostgresSync(world.pool)
    assert sync.review("officer-7", ROADS) is None
    Reviews(world.pool).decide("manager-1", "Amina", ROADS, 1, "sent_back", "Check it.", HASH, 5.0)

    found = sync.review("officer-7", ROADS)

    assert found is not None and (found.version, found.decision, found.note) == (
        1, "sent_back", "Check it.",
    )  # fmt: skip
    assert sync.review("officer-8", ROADS) is None  # not on this mission's team
