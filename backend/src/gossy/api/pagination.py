"""Keyset pagination with opaque cursors (newest first).

A cursor encodes the (timestamp, id) of the last item returned; the next page continues strictly
after it. Stable under concurrent inserts, unlike OFFSET pagination.
"""

from __future__ import annotations

import base64
import json
from datetime import datetime
from typing import Generic, TypeVar

from pydantic import BaseModel, Field

from gossy.api.errors import ApiError

DEFAULT_LIMIT = 100
MAX_LIMIT = 1000

T = TypeVar("T")


class Page(BaseModel, Generic[T]):
    items: list[T]
    nextCursor: str | None = Field(default=None, description="Pass as `cursor` to fetch the next (older) page; null when there are no more items.")


def encode_cursor(ts: datetime, key: str) -> str:
    raw = json.dumps([ts.isoformat(), key], separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, str]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        ts, key = json.loads(base64.urlsafe_b64decode(padded.encode()))
        parsed = datetime.fromisoformat(ts)
        if parsed.tzinfo is None or not isinstance(key, str):
            raise ValueError
        return parsed, key
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        raise ApiError(422, "invalid_cursor", "The pagination cursor is invalid.") from None


def check_time_range(start: datetime | None, end: datetime | None) -> None:
    if start is not None and end is not None and start >= end:
        raise ApiError(422, "invalid_time_range", "`from` must be earlier than `to`.")
