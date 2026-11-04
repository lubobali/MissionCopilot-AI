"""App too old (#103 step 1.10, phone side #104 step 104.7). The phone sends its build number in
X-App-Build on every request. Below MISSIONCOPILOT_MIN_APP_BUILD a phone request gets 403 with
code app_too_old and the minimum, so the app can say "update the app". A missing or garbled header
counts as too old: builds from before this check do not send it.

Answered before the signature check, so a refusal never uses up a sequence number, and it never
deletes anything on the phone (only a valid signed shred order does). The header is not signed:
faking it only gets a phone refused. Health is never refused, so even an old app can read the
server's time; a person's request (the dashboard, no X-Device-Id) is not a phone's."""

from starlette.types import ASGIApp, Receive, Scope, Send

from missioncopilot_backend.errors import problem

ENROLL = "/v1/devices/enroll"
HEALTH = "/v1/health"


class AppVersionMiddleware:
    def __init__(self, app: ASGIApp, min_build: int):
        self.app = app
        self.min_build = min_build

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "http" and self.min_build and self._too_old(scope):
            refusal = problem(
                403,
                "This app build is too old; update the app.",
                code="app_too_old",
                minAppBuild=self.min_build,
            )
            await refusal(scope, receive, send)
            return
        await self.app(scope, receive, send)

    def _too_old(self, scope: Scope) -> bool:
        headers = dict(scope["headers"])
        from_phone = b"x-device-id" in headers or scope["path"] == ENROLL
        if not from_phone or scope["path"] == HEALTH:
            return False
        build = headers.get(b"x-app-build", b"")
        return not build.isdigit() or int(build) < self.min_build
