"""Readiness (#103 step 4.5, S5): health says the process is alive; ready says it can serve, which
needs its directory database. 200 when the directory answers a trivial query within 2 s, 503 with
Retry-After when it does not, so a deploy or a monitor waits instead of sending phones to a server
that would only answer 500. Public, like health; never refused as "app too old"."""

from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator

from missioncopilot_backend.app import create_app
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

SPEC = yaml.safe_load(
    (Path(__file__).resolve().parents[3] / "docs/api/openapi.yaml").read_text(encoding="utf-8")
)


def _ready(answers: bool, **settings):
    app = create_app(Settings(**settings), ready=lambda: answers)
    return local_client(app).get("/v1/ready", headers={"X-Device-Id": "x"})


def test_ready_when_the_directory_answers():
    answer = _ready(True)

    assert answer.status_code == 200
    assert answer.json() == {"status": "ready"}


def test_not_ready_is_a_503_with_retry_after():
    answer = _ready(False)

    assert answer.status_code == 503
    assert answer.headers["content-type"] == "application/problem+json"
    assert answer.headers["retry-after"] == "5"
    assert answer.json()["status"] == 503


def test_without_a_database_the_in_memory_app_is_ready():
    assert local_client(create_app(Settings())).get("/v1/ready").status_code == 200


def test_never_refused_as_an_old_app():
    assert _ready(True, min_app_build=42).status_code == 200


def test_the_answers_match_the_contract():
    pointer = "#/paths/~1v1~1ready/get/responses"
    ok = Draft202012Validator(SPEC | {"$ref": f"{pointer}/200/content/application~1json/schema"})
    down = Draft202012Validator(
        SPEC | {"$ref": "#/components/responses/NotReady/content/application~1problem+json/schema"}
    )

    assert list(ok.iter_errors(_ready(True).json())) == []
    assert list(down.iter_errors(_ready(False).json())) == []
    assert SPEC["paths"]["/v1/ready"]["get"]["responses"]["503"] == {
        "$ref": "#/components/responses/NotReady"
    }
    assert "Retry-After" in SPEC["components"]["responses"]["NotReady"]["headers"]
