"""Security headers on every response (threat model T41), errors and rate-limit answers
included, because this middleware sits outermost. The API only returns data, so its pages may load
nothing and may not be framed. The development docs pages need their scripts, so they skip the
content policy."""

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

ALWAYS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}
CONTENT_POLICY = "default-src 'none'; frame-ancestors 'none'"
HSTS = "max-age=63072000; includeSubDomains"  # two years, HTTPS only


class SecurityHeadersMiddleware:
    def __init__(self, app: ASGIApp, *, hsts: bool, policy_exempt_paths: frozenset[str]):
        self.app = app
        self.hsts = hsts
        self.policy_exempt_paths = policy_exempt_paths

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                for name, value in ALWAYS.items():
                    headers[name] = value
                if scope["path"] not in self.policy_exempt_paths:
                    headers["Content-Security-Policy"] = CONTENT_POLICY
                if self.hsts:
                    headers["Strict-Transport-Security"] = HSTS
            await send(message)

        await self.app(scope, receive, send_with_headers)
