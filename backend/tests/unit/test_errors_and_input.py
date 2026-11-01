"""Errors and input (threat model T36): every error is RFC 9457 Problem Details as the contract
says, a crash never shows its stack trace or message, bad input is named but never echoed back, and
request bodies reject fields we did not define (mass assignment)."""

import pytest
from fastapi import FastAPI
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient
from pydantic import BaseModel

from missioncopilot_backend.app import create_app
from missioncopilot_backend.models import StrictModel
from missioncopilot_backend.settings import Settings

pytestmark = pytest.mark.unit

PROBLEM = "application/problem+json"


class NoteIn(StrictModel):
    text: str


def build_app() -> FastAPI:
    app = create_app(Settings())

    @app.post("/v1/test/notes")
    def add_note(note: NoteIn) -> dict[str, str]:
        return {"text": note.text}

    @app.get("/v1/test/crash")
    def crash() -> None:
        raise RuntimeError("secret connection string postgres://admin:hunter2@db")

    return app


@pytest.fixture
def client() -> TestClient:
    return TestClient(build_app(), raise_server_exceptions=False)


def assert_problem(response, status: int) -> dict:
    assert response.status_code == status
    assert response.headers["content-type"] == PROBLEM
    body = response.json()
    assert {"type", "title", "status"} <= body.keys()
    assert body["status"] == status
    return body


def test_unknown_route_is_a_problem(client):
    assert_problem(client.get("/v1/nothing-here"), 404)


def test_wrong_method_is_a_problem(client):
    assert_problem(client.delete("/v1/health"), 405)


def test_a_crash_shows_no_stack_trace_or_message(client):
    body = assert_problem(client.get("/v1/test/crash"), 500)

    text = str(body)
    assert "hunter2" not in text
    assert "RuntimeError" not in text
    assert "Traceback" not in text


def test_unknown_fields_are_rejected(client):
    body = assert_problem(client.post("/v1/test/notes", json={"text": "ok", "org": "B"}), 422)

    assert ["body", "org"] in [error["loc"] for error in body["errors"]]


def test_bad_input_is_named_but_not_echoed(client):
    body = assert_problem(client.post("/v1/test/notes", json={"text": 12345678}), 422)

    assert "12345678" not in str(body)


def test_valid_input_still_works(client):
    assert client.post("/v1/test/notes", json={"text": "ok"}).json() == {"text": "ok"}


def body_models(app: FastAPI) -> list[object]:
    return [
        param.field_info.annotation
        for route in app.routes
        if isinstance(route, APIRoute)
        for param in route.dependant.body_params
    ]


def is_strict(model: object) -> bool:
    return isinstance(model, type) and issubclass(model, StrictModel)


def test_every_request_body_is_strict():
    models = body_models(build_app())

    assert models, "expected at least one request body to check"
    assert all(is_strict(model) for model in models)


def test_the_strictness_guard_sees_a_loose_model():
    class Loose(BaseModel):
        text: str

    app = create_app(Settings())

    @app.post("/v1/test/loose")
    def loose(body: Loose) -> None: ...

    assert not all(is_strict(model) for model in body_models(app))
