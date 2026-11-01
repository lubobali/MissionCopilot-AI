"""Backend settings, read once from the environment. Safe by default: nothing configured means
production, and an unknown value stops the start instead of guessing."""

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

Environment = Literal["production", "development", "test"]
ENVIRONMENTS: tuple[Environment, ...] = ("production", "development", "test")


@dataclass(frozen=True)
class Settings:
    environment: Environment = "production"
    rate_limit_per_minute: int = 120  # per client address
    max_body_bytes: int = 1_048_576  # 1 MiB; evidence files travel by their own upload later
    allowed_hosts: tuple[str, ...] = ("localhost", "127.0.0.1")  # host names this server answers to
    allowed_origins: tuple[str, ...] = ()  # browser origins (the dashboard); none by default

    def __post_init__(self) -> None:
        if "*" in self.allowed_origins or "*" in self.allowed_hosts:
            raise ValueError("a wildcard origin or host defeats the allow-list; name each one")

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
        )


def _names(value: str | None, default: tuple[str, ...]) -> tuple[str, ...]:
    """A comma-separated list from the environment, or the default when it is not set."""
    if value is None:
        return default
    return tuple(name.strip() for name in value.split(",") if name.strip())
