"""Backend settings, read once from the environment. Safe by default: nothing configured means
production, and an unknown value stops the start instead of guessing."""

import ipaddress
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

Environment = Literal["production", "development", "test"]
ENVIRONMENTS: tuple[Environment, ...] = ("production", "development", "test")
LOCAL_NAMES = frozenset({"localhost", "127.0.0.1", "::1"})


@dataclass(frozen=True)
class Settings:
    environment: Environment = "production"
    rate_limit_per_minute: int = 120  # per client address
    max_body_bytes: int = 1_048_576  # 1 MiB; evidence files travel by their own upload later
    allowed_hosts: tuple[str, ...] = ("localhost", "127.0.0.1")  # host names this server answers to
    allowed_origins: tuple[str, ...] = ()  # browser origins (the dashboard); none by default
    host: str = "127.0.0.1"  # where the server listens: this machine only unless told otherwise
    port: int = 8110
    # The reverse proxy whose X-Forwarded-For is believed (addresses or networks). None by default:
    # anyone can write that header, and on a shared server other programs can reach loopback.
    forwarded_allow_ips: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if "*" in self.allowed_origins or "*" in self.allowed_hosts:
            raise ValueError("a wildcard origin or host defeats the allow-list; name each one")
        _check_process(self.host, self.port, self.forwarded_allow_ips)

    def unsafe(self) -> list[str]:
        """Why production must not start with these settings (empty: fine). Development and tests
        keep their local defaults."""
        if self.environment != "production":
            return []
        problems = []
        if set(self.allowed_hosts) <= LOCAL_NAMES:
            problems.append(
                "MISSIONCOPILOT_ALLOWED_HOSTS names only this machine; add the server's DNS name "
                "(127.0.0.1 may stay, for the container healthcheck)"
            )
        return problems

    @property
    def docs_enabled(self) -> bool:
        """The API docs pages map every route, so production never serves them (threat T35)."""
        return self.environment != "production"

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Settings":
        environment = env.get("MISSIONCOPILOT_ENV", "production")
        if environment not in ENVIRONMENTS:
            raise ValueError(
                f"MISSIONCOPILOT_ENV must be one of {ENVIRONMENTS}, got {environment!r}"
            )
        return cls(
            environment=environment,
            allowed_hosts=_names(env.get("MISSIONCOPILOT_ALLOWED_HOSTS"), cls.allowed_hosts),
            allowed_origins=_names(env.get("MISSIONCOPILOT_ALLOWED_ORIGINS"), cls.allowed_origins),
            host=env.get("MISSIONCOPILOT_HOST", cls.host),
            port=_whole_number(env, "MISSIONCOPILOT_PORT", cls.port),
            forwarded_allow_ips=_names(env.get(FORWARDED), cls.forwarded_allow_ips),
        )


FORWARDED = "MISSIONCOPILOT_FORWARDED_ALLOW_IPS"


def _whole_number(env: Mapping[str, str], name: str, default: int) -> int:
    value = env.get(name)
    if value is None:
        return default
    if not value.isdigit():
        raise ValueError(f"{name} must be a whole number, got {value!r}")
    return int(value)


def _check_process(host: str, port: int, trusted: tuple[str, ...]) -> None:
    """Addresses only: uvicorn would quietly keep a mistyped proxy as text that never matches, and
    a host name could resolve to anything."""
    try:
        ipaddress.ip_address(host)
    except ValueError:
        raise ValueError(f"MISSIONCOPILOT_HOST must be an IP address, got {host!r}") from None
    if not 1 <= port <= 65535:
        raise ValueError(f"MISSIONCOPILOT_PORT must be 1 to 65535, got {port}")
    for entry in trusted:
        try:
            ipaddress.ip_network(entry)  # strict: 10.0.0.1/8 is a typo, not a network
        except ValueError:
            raise ValueError(
                f"{FORWARDED}: {entry!r} is not an address or network; name the proxy itself"
            ) from None


def _names(value: str | None, default: tuple[str, ...]) -> tuple[str, ...]:
    """A comma-separated list from the environment, or the default when it is not set."""
    if value is None:
        return default
    return tuple(name.strip() for name in value.split(",") if name.strip())


def read_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE lines from a local env file, comments and blank lines skipped; no file gives {}."""
    if not path.exists():
        return {}
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.lstrip().startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values
