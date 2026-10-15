"""ULID generation (Crockford base32, 48-bit millisecond timestamp + 80 random bits).

Message IDs are ULIDs so that they are globally unique (idempotency keys for ingestion)
and sortable by creation time.
"""

from __future__ import annotations

import os
import re
import time

_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
_DECODE = {c: i for i, c in enumerate(_ALPHABET)}

# 26 chars encode 130 bits; a 128-bit ULID therefore always starts with 0-7.
ULID_PATTERN = r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$"
_ULID_RE = re.compile(ULID_PATTERN)
_MAX_TIMESTAMP_MS = (1 << 48) - 1


def new_ulid(timestamp_ms: int | None = None, randomness: bytes | None = None) -> str:
    ts = int(time.time() * 1000) if timestamp_ms is None else timestamp_ms
    if not 0 <= ts <= _MAX_TIMESTAMP_MS:
        raise ValueError("timestamp_ms out of ULID range")
    rnd = os.urandom(10) if randomness is None else randomness
    if len(rnd) != 10:
        raise ValueError("randomness must be exactly 10 bytes")
    value = (ts << 80) | int.from_bytes(rnd, "big")
    chars = []
    for _ in range(26):
        chars.append(_ALPHABET[value & 0x1F])
        value >>= 5
    return "".join(reversed(chars))


def is_ulid(value: str) -> bool:
    return bool(_ULID_RE.match(value))


def ulid_timestamp_ms(ulid: str) -> int:
    if not is_ulid(ulid):
        raise ValueError("not a ULID")
    value = 0
    for c in ulid[:10]:
        value = (value << 5) | _DECODE[c]
    return value
