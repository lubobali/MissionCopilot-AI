"""POST /v1/missions/{id}/sync on a real server (#172, step 8.2.3): a team member's phone sends the
approved report; the server checks it (sync_checks.py), stores it in one transaction and answers
with a receipt. The same batch again answers the first receipt; a refused batch stores nothing."""

import json
import uuid

import psycopg
import pytest
from psycopg.conninfo import make_conninfo

from tests.db.phone_world import ROADS
from tests.db.postgres import admin_url
from tests.unit.sync_batches import PhoneBatch

pytestmark = pytest.mark.db

PATH = f"/v1/missions/{ROADS}/sync"


def phone_batch(world, who: str = "officer-7") -> PhoneBatch:
    """A batch signed with the enrolled phone's own key, its approval key kept by the server."""
    phone = world.phones[who]
    batch = PhoneBatch(ROADS, device_key=phone.key)
    world.approval_keys.add(phone.id, batch.approval_der)
    return batch


def send(world, body: dict, who: str = "officer-7", key: str | None = None):
    data = json.dumps(body).encode()
    return world.post(who, PATH, data, {"Idempotency-Key": key or str(uuid.uuid4())})


def test_an_approved_report_is_received(world):
    response = send(world, phone_batch(world).body())

    assert response.status_code == 201
    receipt = response.json()
    assert receipt["itemCount"] == 9 and receipt["alreadyApplied"] is False
    assert uuid.UUID(receipt["batchId"]) and receipt["receivedAt"].endswith("Z")
    synced = [e for e in world_audit(world) if e == "mission_synced"]
    assert synced == ["mission_synced"]


def test_the_same_batch_again_answers_the_first_receipt(world):
    batch, key = phone_batch(world), str(uuid.uuid4())
    first = send(world, batch.body(), key=key).json()

    again = send(world, batch.body(), key=key)
    other_key = send(world, batch.body())  # a retry with a new key: the same approved draft

    assert again.status_code == 200 and again.json() == first | {"alreadyApplied": True}
    assert other_key.status_code == 200 and other_key.json()["batchId"] == first["batchId"]


def test_a_refused_batch_stores_nothing_and_says_why(world):
    batch = phone_batch(world)
    body = batch.body()
    body["sentences"][0]["text"] = "Changed after the approval."

    refused = send(world, body)
    then = send(world, batch.body())

    assert refused.status_code == 422 and refused.json()["detail"] == "approval:not_this_report"
    assert then.status_code == 201, "the refused one left nothing behind"


def test_an_unknown_approval_key_is_refused(world):
    phone = world.phones["officer-7"]
    body = PhoneBatch(ROADS, device_key=phone.key).body()  # its approval key never sent

    assert send(world, body).status_code == 422


def test_another_team_gets_not_found(world):
    assert send(world, phone_batch(world).body(), who="officer-8").status_code == 404


def test_another_organizations_phone_cannot_use_this_phones_batch(world):
    """The other organization has its own mission of this id: this phone's chain is not its own."""
    response = send(world, phone_batch(world).body(), who="other-org")

    assert response.status_code == 409 and response.json()["detail"] == "chain:head_bad_signature"


def test_the_idempotency_key_is_needed_and_must_be_a_uuid(world):
    data = json.dumps(phone_batch(world).body()).encode()

    assert world.post("officer-7", PATH, data).status_code == 422
    assert world.post("officer-7", PATH, data, {"Idempotency-Key": "not-a-uuid"}).status_code == 422


def test_the_sync_route_takes_a_bigger_body_than_others(world):
    batch = phone_batch(world)
    body = batch.body()
    body["facts"][0]["value"] = "x" * 19_000
    body["facts"] = body["facts"] + [
        body["facts"][0] | {"id": f"pad-{i}", "sources": [{"seq": 1}]} for i in range(80)
    ]
    assert len(json.dumps(body)) > 1_048_576

    assert send(world, body).status_code != 413, "over 1 MiB, under 4 MiB"


def world_audit(world) -> list[str]:
    from missioncopilot_backend.db.directory import Directory

    with Directory.open(world.directory_url, world.clock) as directory:
        return [event.kind for event in directory.audit.events()]


def org_admin(world) -> str:
    with psycopg.connect(world.directory_url) as conn:
        row = conn.execute("SELECT database FROM organizations WHERE id = %s", [world.orgs[0]])
        found = row.fetchone()
    assert found is not None
    return make_conninfo(admin_url(), dbname=found[0])


def test_a_second_report_waits_for_a_send_back(world):
    """#178: the received report stands; only a manager's send back opens the next version."""
    batch = phone_batch(world)
    first = batch.body()
    assert send(world, first).status_code == 201
    second = PhoneBatch(ROADS, device_key=batch.device_key, approval_key=batch.approval_key,
                        draft="draft-2").body()  # fmt: skip

    again = send(world, second | {"evidence": first["evidence"], "head": first["head"]})

    assert again.status_code == 409 and again.json()["detail"] == "report:already_received"


def test_the_phone_learns_the_managers_decision(world):
    """#178, 8.8.0: on its next contact; 404 until a manager decides; only the mission's team."""
    path = f"/v1/missions/{ROADS}/report/review"
    assert send(world, phone_batch(world).body()).status_code == 201
    assert world.get("officer-7", path).status_code == 404
    with psycopg.connect(org_admin(world)) as conn:
        conn.execute(
            "INSERT INTO report_reviews (mission_id, version, decision, note, reviewer_id,"
            " reviewer_name, reviewed_at, approval_hash) VALUES (%s, 1, 'sent_back',"
            " 'Check the bridge numbers.', 'manager-1', 'Amina', 1794280000, %s)",
            [ROADS, "c" * 64],
        )

    found = world.get("officer-7", path)

    assert found.status_code == 200
    assert found.json() == {"version": 1, "decision": "sent_back",
                            "reviewedAt": "2026-11-10T03:06:40Z",
                            "note": "Check the bridge numbers."}  # fmt: skip
    assert world.get("officer-8", path).status_code == 404  # another team
