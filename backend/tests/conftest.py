from __future__ import annotations

import json
from datetime import UTC, datetime

import pytest

from gossy.ids import new_ulid

NOW = datetime(2026, 9, 29, 12, 0, 0, tzinfo=UTC)


def envelope(kind_schema: str, device_id: str, data: dict, **overrides) -> dict:
    env = {
        "schema": kind_schema,
        "msgId": new_ulid(),
        "deviceId": device_id,
        "seq": 1,
        "ts": NOW.isoformat(),
        "data": data,
    }
    env.update(overrides)
    return env


def as_bytes(obj: dict) -> bytes:
    return json.dumps(obj).encode()


@pytest.fixture
def now() -> datetime:
    return NOW
