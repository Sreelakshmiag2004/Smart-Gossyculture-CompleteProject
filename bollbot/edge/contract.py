"""Cart records -> backend MQTT contract `bollbot/v1` (backend/docs/mqtt-contract.md).

The cart's outbox stores records in its own shape (Modules 3-5). This module
turns each one into the contract's envelope + data, exactly as the backend's
Pydantic models expect (camelCase, strict types, ranges). It is pure, so it
is tested here and its output is also validated by the backend's own models
(backend/tests/unit/test_cart_samples.py).
"""
from __future__ import annotations

import os
import re
import time
from typing import Optional

TOPIC_ROOT = "bollbot/v1"
DEVICE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,63}$")
SCHEMAS = {
    "telemetry": "bollbot.telemetry/1",
    "event/spray": "bollbot.event.spray/1",
    "event/scan": "bollbot.event.scan/1",
    "event/pick": "bollbot.event.pick/1",
    "status": "bollbot.status/1",
}
# outbox kind -> contract kind
KINDS = {"heartbeat": "telemetry", "scan": "event/scan", "spray_event": "event/spray",
         "pick_attempt": "event/pick"}
SEGMENT_RE = re.compile(r"^R(\d{1,5})-S(\d{1,5})$")
PICK_ID_RE = re.compile(r"^[a-z0-9-]{1,32}$")

_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


class NotForCloud(ValueError):
    """The record cannot be expressed in the contract (permanent: do not retry)."""


def new_ulid(timestamp_ms: Optional[int] = None) -> str:
    """ULID: 48-bit ms timestamp + 80 random bits, Crockford base32 (same as backend gossy.ids)."""
    ts = int(time.time() * 1000) if timestamp_ms is None else timestamp_ms
    value = (ts << 80) | int.from_bytes(os.urandom(10), "big")
    return "".join(_ALPHABET[(value >> (5 * i)) & 0x1F] for i in reversed(range(26)))


def check_device_id(device_id: str) -> str:
    if not DEVICE_ID_RE.match(device_id) or device_id.startswith("svc-"):
        raise ValueError(f"cart_id {device_id!r} is not a valid contract deviceId "
                         "(lowercase letters, digits, '-', 3-64 chars, not starting with 'svc-')")
    return device_id


def topic(device_id: str, kind: str) -> str:
    return f"{TOPIC_ROOT}/{device_id}/{kind}"


def _camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(w.capitalize() for w in rest)


def _num(v, lo: float, hi: float) -> Optional[float]:
    """A reading inside the contract range, else None (omitted, never faked)."""
    if v is None:
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if lo <= f <= hi else None


def _put(d: dict, key: str, value) -> None:
    if value is not None:
        d[key] = value


def _weather(w: Optional[dict]) -> dict:
    out: dict = {}
    if not w:
        return out
    _put(out, "airTempC", _num(w.get("t_c"), -40, 85))
    rh = _num(w.get("rh"), 0, 105)
    _put(out, "airRhPct", None if rh is None else min(rh, 100.0))   # capacitive sensors read >100 at saturation
    _put(out, "dewpointC", _num(w.get("dewpoint_c"), -40, 60))
    return out


def _segment(key) -> tuple[Optional[int], Optional[int]]:
    m = SEGMENT_RE.match(key or "")
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def _text(v, n: int) -> Optional[str]:
    if v in (None, "", "none"):
        return None
    return str(v)[:n]


def data_for(kind: str, p: dict) -> dict:
    """Contract `data` object for one outbox record. Raises NotForCloud."""
    if kind == "heartbeat":
        d = _weather(p.get("weather"))
        _put(d, "fps", _num(p.get("fps"), 0, 1000))
        pending = (p.get("outbox") or {}).get("pending")
        if isinstance(pending, int) and pending >= 0:
            d["outboxPending"] = pending
        _put(d, "batteryPct", _num(p.get("battery_pct"), 0, 100))
        if not d:
            raise NotForCloud("heartbeat has no readings")
        return d

    if kind == "scan":
        counts = {_camel(k): int(v) for k, v in (p.get("counts") or {}).items() if int(v) > 0}
        d = {"row": int(p["row"]), "segment": int(p["segment"]), "counts": counts,
             "startedAt": p["started"], "frames": int(p.get("frames", 0)),
             "model": str(p.get("model") or "unknown")[:64]}
        d.update(_weather(p.get("weather")))
        return d

    if kind == "spray_event":
        completed = bool(p.get("completed"))
        ms_on = int(p.get("ms_on") or 0)
        if ms_on == 0 and completed:
            raise NotForCloud("completed spray with 0 ms")
        d = {"durationMs": min(ms_on, 60_000), "completed": completed}
        _put(d, "reason", _text(p.get("reason"), 64))
        _put(d, "mlRequested", _num(p.get("ml_requested"), 0, 10_000))
        _put(d, "mlDelivered", _num(p.get("ml_delivered"), 0, 10_000))
        _put(d, "purpose", _text(p.get("purpose"), 32))
        row, seg = _segment(p.get("segment"))
        _put(d, "row", row)
        _put(d, "segment", seg)
        return d

    if kind == "pick_attempt":
        aid = str(p.get("id", ""))
        if not PICK_ID_RE.match(aid):
            raise NotForCloud(f"pick attempt id {aid!r} not allowed by the contract")
        d = {"attemptId": aid, "result": p["result"]}
        _put(d, "reason", _text(p.get("reason"), 256))
        row, seg = _segment(p.get("segment"))
        _put(d, "row", row)
        _put(d, "segment", seg)
        tid = p.get("track_id")
        if isinstance(tid, int) and tid >= 0:
            d["trackId"] = tid
        _put(d, "confidence", _num(p.get("conf"), 0, 1))
        _put(d, "pitchDeg", _num(p.get("pitch_deg"), -90, 90))
        _put(d, "cycleS", _num(p.get("cycle_s"), 0, 600))
        if p.get("outcome") in ("picked", "partial", "missed", "damaged"):
            d["outcome"] = p["outcome"]
        _put(d, "lintLeftG", _num(p.get("lint_left_g"), 0, 1000))
        _put(d, "trashG", _num(p.get("trash_g"), 0, 1000))
        return d

    raise NotForCloud(f"outbox kind '{kind}' has no contract message")


def envelope(kind: str, payload: dict, device_id: str, msg_id: str, seq: int) -> tuple[str, dict]:
    """(topic, envelope) for an outbox record."""
    ck = KINDS.get(kind)
    if ck is None:
        raise NotForCloud(f"outbox kind '{kind}' has no contract message")
    ts = payload.get("ts")
    if not ts or not re.search(r"(Z|[+-]\d\d:\d\d)$", str(ts)):
        raise NotForCloud("timestamp missing or without timezone")
    return topic(device_id, ck), {"schema": SCHEMAS[ck], "msgId": msg_id, "deviceId": device_id,
                                  "seq": int(seq), "ts": ts, "data": data_for(kind, payload)}


def status_envelope(device_id: str, state: str, ts: str, seq: int) -> tuple[str, dict]:
    return topic(device_id, "status"), {"schema": SCHEMAS["status"], "msgId": new_ulid(),
                                        "deviceId": device_id, "seq": int(seq), "ts": ts,
                                        "data": {"state": state}}
