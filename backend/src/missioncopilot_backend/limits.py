"""Resource limits (threat model T34, API4:2023). A token bucket per client address answers 429
with Retry-After; it tracks a capped number of clients, so many addresses cannot exhaust its memory.
A body over the limit answers 413: refused before reading when Content-Length says so, and counted
while it streams in, because a chunked body declares no length.

The client address is the connection's own. X-Forwarded-For is not trusted here: anyone can send
it. Behind a reverse proxy, run uvicorn with --proxy-headers and --forwarded-allow-ips set to that
proxy only. One process keeps its own counts; a real deployment also limits at the proxy."""

import math
import time
from collections import OrderedDict
from collections.abc import Callable

from starlette.exceptions import HTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from missioncopilot_backend.audit import AuditLog, Kind
from missioncopilot_backend.errors import problem


class RateLimiter:
    def __init__(
        self,
        per_minute: int,
        clock: Callable[[], float] = time.monotonic,
        max_clients: int = 10_000,
    ):
        self._capacity = float(per_minute)
        self._refill_per_second = per_minute / 60
        self._clock = clock
        self._max_clients = max_clients
        self._buckets: OrderedDict[str, tuple[float, float]] = OrderedDict()

    def check(self, client: str) -> int:
        """0 if the request may go ahead, else the seconds to wait."""
        now = self._clock()
        tokens, last = self._buckets.pop(client, (self._capacity, now))
        tokens = min(self._capacity, tokens + (now - last) * self._refill_per_second)
        wait = 0
        if tokens >= 1:
            tokens -= 1
        else:
            wait = math.ceil((1 - tokens) / self._refill_per_second)
        self._buckets[client] = (tokens, now)  # most recent last
        while len(self._buckets) > self._max_clients:
            self._buckets.popitem(last=False)  # forget the least recent client
        return wait

    def tracked_clients(self) -> int:
        return len(self._buckets)


class LimitsMiddleware:
    def __init__(
        self, app: ASGIApp, limiter: RateLimiter, max_body_bytes: int, audit: AuditLog | None = None
    ):
        self.app = app
        self.limiter = limiter
        self.max_body_bytes = max_body_bytes
        self.audit = audit
        self._blocked: OrderedDict[str, None] = OrderedDict()  # recorded once per blocking spell

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        client = scope.get("client")
        address = client[0] if client else "unknown"
        wait = self.limiter.check(address)
        if wait:
            self._note_blocked(address)
            response = problem(429)
            response.headers["Retry-After"] = str(wait)
            await response(scope, receive, send)
            return
        self._blocked.pop(address, None)
        declared = dict(scope["headers"]).get(b"content-length")
        if declared is not None and (not declared.isdigit() or int(declared) > self.max_body_bytes):
            self._record("body_too_large", address)
            await problem(413 if declared.isdigit() else 400)(scope, receive, send)
            return
        await self.app(scope, self._counting(receive, address), send)

    def _note_blocked(self, address: str) -> None:
        """Record when a client starts being refused, not every refusal: a flood of 429s must not
        flood the audit log."""
        if address in self._blocked:
            return
        self._blocked[address] = None
        while len(self._blocked) > 10_000:
            self._blocked.popitem(last=False)
        self._record("rate_limited", address)

    def _record(self, kind: Kind, address: str) -> None:
        if self.audit is not None:
            self.audit.record(kind, client=address)

    def _counting(self, receive: Receive, address: str) -> Receive:
        received = 0

        async def counted() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_body_bytes:
                    self._record("body_too_large", address)
                    raise HTTPException(413)  # becomes a Problem through the error handlers
            return message

        return counted
