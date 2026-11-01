"""Resource limits (threat model T34, API4:2023): too many requests from one client get 429 with
Retry-After, the limiter's own memory is capped so many addresses cannot exhaust it, and a body over
the limit is refused with 413, also when it is sent without a Content-Length (chunked)."""

import asyncio

import pytest
from fastapi import FastAPI, Request

from missioncopilot_backend.app import create_app
from missioncopilot_backend.limits import LimitsMiddleware, RateLimiter
from missioncopilot_backend.settings import Settings
from tests.unit.clients import local_client

pytestmark = pytest.mark.unit

PROBLEM = "application/problem+json"


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def test_a_client_gets_its_limit_then_waits():
    clock = Clock()
    limiter = RateLimiter(per_minute=3, clock=clock)

    assert [limiter.check("1.2.3.4") for _ in range(4)] == [0, 0, 0, 20]
    clock.now += 20
    assert limiter.check("1.2.3.4") == 0


def test_clients_are_counted_separately():
    limiter = RateLimiter(per_minute=1, clock=Clock())

    assert limiter.check("1.1.1.1") == 0
    assert limiter.check("2.2.2.2") == 0
    assert limiter.check("1.1.1.1") > 0


def test_the_limiter_memory_is_capped():
    limiter = RateLimiter(per_minute=1, clock=Clock(), max_clients=100)

    for n in range(10_000):
        limiter.check(f"10.0.{n // 256}.{n % 256}")

    assert limiter.tracked_clients() <= 100


def build_app(per_minute: int = 1000, max_body_bytes: int = 1000) -> FastAPI:
    settings = Settings(rate_limit_per_minute=per_minute, max_body_bytes=max_body_bytes)
    app = create_app(settings, clock=Clock())

    @app.post("/v1/test/upload")
    async def upload(request: Request) -> dict[str, int]:
        return {"bytes": len(await request.body())}

    return app


def test_too_many_requests_get_a_429_problem_with_retry_after():
    client = local_client(build_app(per_minute=2))

    statuses = [client.get("/v1/health").status_code for _ in range(3)]
    response = client.get("/v1/health")

    assert statuses == [200, 200, 429]
    assert response.headers["content-type"] == PROBLEM
    assert int(response.headers["retry-after"]) > 0


def test_a_body_under_the_limit_passes():
    client = local_client(build_app(max_body_bytes=1000))

    assert client.post("/v1/test/upload", content=b"x" * 1000).json() == {"bytes": 1000}


def test_a_declared_large_body_is_refused():
    client = local_client(build_app(max_body_bytes=1000))

    response = client.post("/v1/test/upload", content=b"x" * 1001)

    assert response.status_code == 413
    assert response.headers["content-type"] == PROBLEM


def test_a_chunked_large_body_is_refused():
    client = local_client(build_app(max_body_bytes=1000))

    def chunks():
        for _ in range(5):
            yield b"x" * 300

    response = client.post("/v1/test/upload", content=chunks())

    assert response.status_code == 413


def test_a_declared_large_body_is_refused_before_reading_it():
    async def app(scope, receive, send):
        raise AssertionError("the app must not run")

    async def receive():
        raise AssertionError("the body must not be read")

    sent = []

    async def send(message):
        sent.append(message)

    middleware = LimitsMiddleware(app, RateLimiter(per_minute=60), max_body_bytes=1000)
    scope = {
        "type": "http",
        "method": "POST",
        "path": "/v1/x",
        "client": ("1.2.3.4", 1),
        "headers": [(b"content-length", b"10000000")],
    }

    asyncio.run(middleware(scope, receive, send))

    assert sent[0]["status"] == 413
