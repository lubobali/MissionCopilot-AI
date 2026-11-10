"""Evidence files on a real server (#172, step 8.2.4): after a sync, the phone sends each item's
file; the server keeps it only when its SHA-256 is the contentHash the phone signed, so the report
page can show the photo or scan behind a sentence (#177). Same file again: fine; wrong bytes:
refused."""

import json
import uuid

import pytest

from tests.db.phone_world import ROADS
from tests.db.test_sync_routes import phone_batch
from tests.unit.sync_batches import content

pytestmark = pytest.mark.db


def synced(world) -> None:
    body = json.dumps(phone_batch(world).body()).encode()
    path = f"/v1/missions/{ROADS}/sync"
    assert (
        world.post("officer-7", path, body, {"Idempotency-Key": str(uuid.uuid4())}).status_code
        == 201
    )


def upload(world, seq: int, data: bytes, who: str = "officer-7"):
    path = f"/v1/missions/{ROADS}/evidence/{seq}/file"
    return world.post(who, path, data, {"Content-Type": "application/octet-stream"})


def test_the_signed_file_is_kept_once(world):
    synced(world)

    first = upload(world, 1, content(1))
    again = upload(world, 1, content(1))

    assert first.status_code == 201 and again.status_code == 200
    assert first.json() == {"seq": 1, "sha256": first.json()["sha256"]}


def test_bytes_that_are_not_the_signed_file_are_refused(world):
    synced(world)

    response = upload(world, 1, b"another photo")

    assert response.status_code == 422 and response.json()["detail"] == "file:not_the_signed_one"
    assert upload(world, 1, content(1)).status_code == 201, "the refused bytes left nothing"


def test_an_item_never_received_or_another_team_gets_not_found(world):
    synced(world)

    assert upload(world, 99, content(1)).status_code == 404
    assert upload(world, 1, content(1), who="officer-8").status_code == 404


def test_a_file_bigger_than_the_default_body_is_taken(world):
    synced(world)

    response = upload(world, 1, b"x" * (2 * 1_048_576))

    assert response.status_code == 422, "over 1 MiB reaches the check (here: not the signed bytes)"
