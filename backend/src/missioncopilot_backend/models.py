from pydantic import BaseModel, ConfigDict


class StrictModel(BaseModel):
    """Base for every request body: a field we did not define is an error, not silently ignored,
    so a client can never set something like the organization through the body (threat T36)."""

    model_config = ConfigDict(extra="forbid")
