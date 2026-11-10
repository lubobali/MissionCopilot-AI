"""What a phone sends when it syncs an approved report (#172, ADR 0006): the mission's signed
evidence chain and its head, the facts the report cites with their rules and sources, the approved
draft's sentences, and the officer's Face ID approval (the exact bytes signed, the signature, the
key id). Strict: a field we did not define is refused (threat T36); bytes travel as base64, as
Swift's JSONEncoder writes them."""

import base64
import binascii
from typing import Literal

from pydantic import Field

from missioncopilot_backend.evidence import Record
from missioncopilot_backend.models import StrictModel

Classification = Literal["strictly_confidential", "official_use_only", "public"]
Section = Literal["mission", "project", "findings", "agreedActions", "nextSteps"]
ID = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9:._-]+$")


def decode(text: str) -> bytes | None:
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return None


class SignedItem(StrictModel):
    payload: str = Field(min_length=1, max_length=200_000)
    signature: str = Field(min_length=1, max_length=200)

    def record(self) -> Record | None:
        payload, signature = decode(self.payload), decode(self.signature)
        return None if payload is None or signature is None else Record(payload, signature)


class FactSource(StrictModel):
    seq: int = Field(ge=1, le=1_000_000)
    region: str | None = Field(default=None, max_length=4000)


class SyncFact(StrictModel):
    id: str = ID
    name: str = Field(min_length=1, max_length=200)
    value: str = Field(max_length=20_000)
    unit: str | None = Field(default=None, max_length=40)
    ruleId: str = Field(min_length=1, max_length=64)
    ruleVersion: str = Field(min_length=1, max_length=16)
    classification: Classification
    sources: list[FactSource] = Field(min_length=1, max_length=100)


class SyncSentence(StrictModel):
    id: str = ID
    section: Section
    text: str = Field(min_length=1, max_length=4000)
    classification: Classification
    factIds: list[str] = Field(min_length=1, max_length=100)


class SyncApproval(StrictModel):
    payload: str = Field(min_length=1, max_length=400_000)
    signature: str = Field(min_length=1, max_length=200)
    keyId: str = Field(pattern=r"^[0-9a-f]{64}$")


class SyncBatch(StrictModel):
    evidence: list[SignedItem] = Field(min_length=1, max_length=10_000)
    head: SignedItem
    facts: list[SyncFact] = Field(max_length=5000)
    draftId: str = ID
    language: Literal["en", "fr"]
    sentences: list[SyncSentence] = Field(min_length=1, max_length=500)
    approval: SyncApproval
