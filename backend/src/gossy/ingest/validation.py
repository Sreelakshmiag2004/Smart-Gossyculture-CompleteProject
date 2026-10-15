"""System-boundary validation for incoming MQTT messages.

A message is accepted only if: size is within limit, the topic is a known v1 topic, the JSON
matches the typed schema for that topic, the schema id matches the topic kind, the envelope
deviceId equals the topic deviceId (which the broker ACL binds to the authenticated username),
and the device timestamp is not implausibly far in the future.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta

from pydantic import ValidationError

from gossy.contracts.messages import ENVELOPE_MODELS, SCHEMA_IDS, Envelope
from gossy.contracts.topics import MessageKind, TopicError, parse_topic


class RejectedMessage(Exception):
    def __init__(self, reason: str, detail: str | None = None):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


@dataclass(frozen=True)
class ValidMessage:
    topic: str
    kind: MessageKind
    envelope: Envelope


def _summarise(error: ValidationError, limit: int = 5) -> str:
    # Location + error type only: never echo input values (they may be large or sensitive).
    parts = [f"{'.'.join(str(p) for p in e['loc']) or '<root>'}:{e['type']}" for e in error.errors()[:limit]]
    if error.error_count() > limit:
        parts.append(f"+{error.error_count() - limit} more")
    return "; ".join(parts)


def parse_message(
    topic: str,
    payload: bytes,
    *,
    now: datetime,
    max_payload_bytes: int,
    max_future_skew: timedelta,
) -> ValidMessage:
    if len(payload) > max_payload_bytes:
        raise RejectedMessage("payload_too_large", f"{len(payload)} > {max_payload_bytes} bytes")
    try:
        parsed = parse_topic(topic)
    except TopicError as exc:
        raise RejectedMessage("invalid_topic", str(exc)) from None
    try:
        envelope = ENVELOPE_MODELS[parsed.kind].model_validate_json(payload)
    except ValidationError as exc:
        raise RejectedMessage("schema_validation_failed", _summarise(exc)) from None
    expected_schema = SCHEMA_IDS[parsed.kind]
    if envelope.schema_id != expected_schema:
        raise RejectedMessage("schema_mismatch", f"expected {expected_schema}, got {envelope.schema_id}")
    if envelope.device_id != parsed.device_id:
        raise RejectedMessage("device_id_mismatch", "envelope deviceId differs from topic deviceId")
    if envelope.ts - now > max_future_skew:
        raise RejectedMessage("timestamp_in_future", f"ts exceeds allowed skew of {max_future_skew}")
    return ValidMessage(topic=topic, kind=parsed.kind, envelope=envelope)
