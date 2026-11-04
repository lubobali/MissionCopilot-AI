"""No database call runs on the event loop (#103 step 4.1, S1). The server has one event loop: a
blocking call there freezes every request, health included, while it waits. The phone's
signature check and the limits layer talk to Postgres (device lookup, sequence number, audit
log), so those calls run in the thread pool. Each test makes the database slow (1 s) and checks
that health still answers at once while a request waits on it."""

import threading
import time

import pytest
from fastapi import Depends
from fastapi.testclient import TestClient

from missioncopilot_backend.app import create_app
from missioncopilot_backend.audit import AuditLog
from missioncopilot_backend.device_auth import DevicePrincipal, device_router, require_device
from missioncopilot_backend.devices import DeviceRegistry
from missioncopilot_backend.settings import Settings
from tests.unit.test_device_requests import BODY, PATH, Clock, Phone

pytestmark = pytest.mark.unit

SLOW = 1.0  # seconds the "database" takes
QUICK = 0.5  # health must answer well within the slow call


class SlowDevices(DeviceRegistry):
    def find(self, device_id: str):
        time.sleep(SLOW)  # a slow query: blocking, like psycopg
        return super().find(device_id)


class SlowAudit(AuditLog):
    def record(self, kind, **fields):
        time.sleep(SLOW)
        return super().record(kind, **fields)


def _health_while(client: TestClient, slow_request) -> float:
    """Seconds health takes while slow_request is waiting on the database."""
    worker = threading.Thread(target=slow_request)
    worker.start()
    time.sleep(0.2)  # the slow request is now inside its database call
    started = time.monotonic()
    assert client.get("/v1/health").status_code == 200
    took = time.monotonic() - started
    worker.join()
    return took


def test_a_slow_device_lookup_does_not_freeze_the_server():
    clock = Clock()
    devices = SlowDevices(clock=clock)
    app = create_app(Settings(), devices=devices, clock=clock)
    router = device_router()

    @router.post("/test/missions/{mission_id}/sync")
    def sync(mission_id: str, device: DevicePrincipal = Depends(require_device)) -> dict:
        return {"device": device.device_id}

    app.include_router(router)
    phone = Phone(devices)
    answers = []
    with TestClient(app, base_url="http://localhost") as client:
        signed = phone.headers(PATH, BODY, clock.now)
        took = _health_while(
            client, lambda: answers.append(client.post(PATH, content=BODY, headers=signed))
        )

    assert took < QUICK, f"health waited {took:.2f} s behind the device lookup"
    assert [a.status_code for a in answers] == [200]  # and the slow request still works


def test_a_slow_audit_write_from_the_limits_layer_does_not_freeze_the_server():
    app = create_app(Settings(rate_limit_per_minute=1), audit=SlowAudit())
    with TestClient(app, base_url="http://localhost") as client:
        client.get("/v1/health")  # the one allowed request; the next is refused and recorded

        def refused():
            assert client.get("/v1/health", headers={"X-Test": "flood"}).status_code == 429

        worker_took = _limited_health(client, refused)

    assert worker_took < QUICK, f"health waited {worker_took:.2f} s behind the audit write"


def _limited_health(client: TestClient, slow_request) -> float:
    """Like _health_while, but health is rate limited here too: time the answer, whatever it is."""
    worker = threading.Thread(target=slow_request)
    worker.start()
    time.sleep(0.2)
    started = time.monotonic()
    client.get("/v1/health")  # 429 too (same address), but it must come at once
    took = time.monotonic() - started
    worker.join()
    return took
