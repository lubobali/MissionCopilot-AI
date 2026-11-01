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
        return cls(environment=environment)
