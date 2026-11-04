"""The nginx site in front of the real container, as on the server (#103 step 6). Called by
scripts/container_check.py once the API is up.

The site is rendered from deploy/nginx/site.conf.template and served by nginx 1.24 (the server's
version) in a throwaway container on the host network, so it reaches the API exactly as the
server's own nginx does: 127.0.0.1:<port>, through Docker, from the API network's gateway. It
listens on test loopback ports only (never 80 or 443) with a throwaway self-signed certificate.
"""

import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from render_nginx_site import TEMPLATES, render  # noqa: E402

NGINX_IMAGE = "nginx:1.24.0@sha256:f6daac2445b0ce70e64d77442ccf62839f3f1b4c24bf6746a857eff014e798c8"
HTTPS, HTTP = 18443, 18080
NAME = "missioncopilot-check-nginx"


def _sh(*command: str) -> str:
    done = subprocess.run(command, capture_output=True, text=True, check=False)  # noqa: S603
    if done.returncode != 0:
        raise RuntimeError(f"{' '.join(command[:3])}...: {done.stderr.strip()[-300:]}")
    return done.stdout.strip()


def start(folder: Path, hostname: str, api_port: int) -> None:
    site = render(
        TEMPLATES["site"], "check", hostname, api_port,
        listen_https=[f"127.0.0.1:{HTTPS} ssl http2"], listen_http=[f"127.0.0.1:{HTTP}"],
        cert_dir="/certs",
    )  # fmt: skip
    (folder / "site.conf").write_text(site, encoding="utf-8")
    _sh("openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
        "-nodes", "-days", "1", "-subj", f"/CN={hostname}",
        "-keyout", str(folder / "privkey.pem"), "-out", str(folder / "fullchain.pem"))  # fmt: skip
    (folder / "privkey.pem").chmod(0o644)  # read by the nginx container's worker; a test key
    _sh("docker", "run", "--detach", "--name", NAME, "--network", "host", "--memory", "64m",
        "-v", f"{folder / 'site.conf'}:/etc/nginx/conf.d/default.conf:ro",
        "-v", f"{folder}:/certs:ro", NGINX_IMAGE)  # fmt: skip


def wait(hostname: str, seconds: int = 20) -> None:
    for _ in range(seconds * 4):
        try:
            request("/v1/health", hostname)
            return
        except OSError:
            time.sleep(0.25)
    raise RuntimeError("nginx did not start (see: docker logs " + NAME + ")")


def stop() -> None:
    subprocess.run(["docker", "rm", "-f", NAME], capture_output=True, check=False)  # noqa: S603, S607 - fixed arguments
    for folder in Path(tempfile.gettempdir()).glob("mc-check-nginx-*"):
        shutil.rmtree(folder, ignore_errors=True)


def request(
    path: str, hostname: str, headers: dict[str, str] | None = None, body: bytes | None = None
):
    context = ssl.create_default_context()
    context.check_hostname, context.verify_mode = False, ssl.CERT_NONE  # the throwaway certificate
    request = urllib.request.Request(  # noqa: S310 - loopback only
        f"https://127.0.0.1:{HTTPS}{path}", data=body, headers={"Host": hostname} | (headers or {})
    )
    try:
        with urllib.request.urlopen(request, timeout=5, context=context) as answer:  # noqa: S310
            return answer.status, {k.lower(): v for k, v in answer.headers.items()}, answer.read()
    except urllib.error.HTTPError as error:
        return error.code, {k.lower(): v for k, v in error.headers.items()}, error.read()


def check(c, hostname: str, phone: str) -> None:
    """c: container_check's Check (expect, run, audit_client)."""
    status, headers, body = request("/v1/health", hostname)
    c.expect("through nginx: health 200 (the real Host reaches the app)", status == 200, status)
    # nginx's default Host would be 127.0.0.1:<port>, which the app allows for its healthcheck:
    # only the real Host makes an unknown name fail, as it must.
    status, _, _ = request("/v1/health", "evil.example")
    c.expect("through nginx: an unknown host name still gets 400", status == 400, status)
    # Appending instead of overwriting would end the same (uvicorn takes the rightmost untrusted
    # address): two layers; scripts/test_render_nginx_site.py pins the overwrite itself.
    request("/v1/devices/me", hostname, {"X-Device-Id": "x", "X-Forwarded-For": phone})
    seen = c.audit_client()
    c.expect(
        "through nginx: a client's own X-Forwarded-For is overwritten", seen == "127.0.0.1", seen
    )
    status, _, _ = request("/v1/health", hostname, body=b"x" * (2 * 1024 * 1024))
    c.expect("through nginx: a 2 MiB body gets 413", status == 413, status)
    flood = [request("/v1/health", hostname) for _ in range(80)]
    limited = [(h.get("retry-after"), h.get("content-type")) for s, h, _ in flood if s == 429]
    ours = ("1", "application/problem+json")
    c.expect("through nginx: a flood gets 429 with Retry-After", ours in limited, limited[:3])
    c.run("stop", "api")
    status, headers, body = request("/v1/health", hostname)
    answer = json.loads(body or b"{}")
    c.expect(
        "through nginx: the app down is a JSON 503 with Retry-After",
        (status, headers.get("retry-after"), answer.get("status")) == (503, "5", 503),
        (status, headers.get("retry-after"), body[:80]),
    )
