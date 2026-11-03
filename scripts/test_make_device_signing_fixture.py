import json

import pytest
from make_device_signing_fixture import FIXTURE, fixture

pytestmark = pytest.mark.unit


def test_the_committed_fixture_is_what_the_server_builds_today():
    assert json.loads(FIXTURE.read_text(encoding="utf-8")) == fixture(), (
        "rerun scripts/make_device_signing_fixture.py"
    )


def test_it_covers_enrollment_reads_a_body_and_a_query():
    requests = fixture()["requests"]

    assert fixture()["enrollment"]
    assert {r["method"] for r in requests} == {"GET", "POST"}
    assert any(r["body"] for r in requests) and any("?" in r["path"] for r in requests)
