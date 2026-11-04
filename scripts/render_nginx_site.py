"""Render MissionCopilot's nginx site file from deploy/nginx/ (#103 step 6).

The runbook writes the result to its own file in /etc/nginx/sites-available; nothing else on the
server is touched. Values are checked: a hostname that could inject nginx syntax, a privileged or
impossible port, an unknown environment or a placeholder left over is refused.

Usage (from the repo root):
  python3 scripts/render_nginx_site.py --env staging --hostname mc-staging.lubot.ai --port 8121
  python3 scripts/render_nginx_site.py --http-only ...   (the first deploy, before the certificate)
"""

import argparse
import re
import sys
from pathlib import Path

NGINX = Path(__file__).resolve().parents[1] / "deploy" / "nginx"
TEMPLATES = {
    "site": (NGINX / "site.conf.template").read_text(encoding="utf-8"),
    "http-only": (NGINX / "site-http-only.conf.template").read_text(encoding="utf-8"),
}
ENVIRONMENTS = ("staging", "prod", "check")
# Lowercase DNS name with at least one dot: nothing nginx would read as syntax.
HOSTNAME = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")


def _listen(lines: list[str]) -> str:
    return "\n".join(f"    listen {line};" for line in lines)


def render(
    template: str,
    env: str,
    hostname: str,
    port: int,
    listen_https: list[str] | None = None,
    listen_http: list[str] | None = None,
    cert_dir: str | None = None,
) -> str:
    if env not in ENVIRONMENTS:
        raise ValueError(f"env must be one of {ENVIRONMENTS}, got {env!r}")
    if not HOSTNAME.match(hostname):
        raise ValueError(f"not a lowercase DNS name: {hostname!r}")
    if not 1024 <= port <= 65535:
        raise ValueError(f"port must be 1024-65535 (the app listens on loopback), got {port}")
    values = {
        "ENV": env,
        "HOSTNAME": hostname,
        "PORT": str(port),
        "LISTEN_HTTPS": _listen(listen_https or ["443 ssl http2", "[::]:443 ssl http2"]),
        "LISTEN_HTTP": _listen(listen_http or ["80", "[::]:80"]),
        "CERT_DIR": cert_dir or f"/etc/letsencrypt/live/{hostname}",
    }
    unknown = sorted(set(PLACEHOLDER.findall(template)) - values.keys())
    if unknown:
        raise ValueError(f"unknown placeholders in the template: {unknown}")
    return PLACEHOLDER.sub(lambda match: values[match.group(1)], template)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--env", required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--http-only", action="store_true")
    args = parser.parse_args(argv)
    template = TEMPLATES["http-only" if args.http_only else "site"]
    try:
        print(render(template, args.env, args.hostname, args.port), end="")
    except ValueError as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
