"""MQTT topic naming: ``bollbot/v1/{deviceId}/{kind}``.

All v1 topics are device → backend. There are deliberately no command/config topics
(Phase 0 ADR-10 and the Phase 1 rule: no backend-to-device operational commands).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum

TOPIC_ROOT = "bollbot"
CONTRACT_VERSION = "v1"

# Device IDs double as the broker username. The "svc-" prefix is reserved for backend
# service accounts so that a service credential can never pass as a device. (Kept as a
# separate rule: the Rust regex engine used by Pydantic does not support look-ahead.)
DEVICE_ID_PATTERN = r"^[a-z0-9][a-z0-9-]{2,63}$"
RESERVED_SERVICE_PREFIX = "svc-"
_DEVICE_ID_RE = re.compile(DEVICE_ID_PATTERN)


class MessageKind(StrEnum):
    TELEMETRY = "telemetry"
    PEST = "event/pest"
    SPRAY = "event/spray"
    HARVEST = "event/harvest"   # Phase I form; superseded by event/scan + event/pick (kept for compatibility)
    SCAN = "event/scan"         # Phase II: boll and pest-sign counts for one row segment
    PICK = "event/pick"         # Phase II: one robotic pick attempt (experiment E10)
    STATUS = "status"


# Subscriptions used by the ingest service (read-only in the broker ACL).
INGEST_SUBSCRIPTIONS: tuple[str, ...] = (
    f"{TOPIC_ROOT}/{CONTRACT_VERSION}/+/telemetry",
    f"{TOPIC_ROOT}/{CONTRACT_VERSION}/+/event/+",
    f"{TOPIC_ROOT}/{CONTRACT_VERSION}/+/status",
)


class TopicError(ValueError):
    pass


@dataclass(frozen=True)
class ParsedTopic:
    device_id: str
    kind: MessageKind


def is_valid_device_id(device_id: str) -> bool:
    return bool(_DEVICE_ID_RE.match(device_id)) and not device_id.startswith(RESERVED_SERVICE_PREFIX)


def topic_for(device_id: str, kind: MessageKind) -> str:
    if not is_valid_device_id(device_id):
        raise TopicError(f"invalid device id: {device_id!r}")
    return f"{TOPIC_ROOT}/{CONTRACT_VERSION}/{device_id}/{MessageKind(kind).value}"


def parse_topic(topic: str) -> ParsedTopic:
    parts = topic.split("/")
    if len(parts) < 4 or parts[0] != TOPIC_ROOT:
        raise TopicError("unknown topic root")
    if parts[1] != CONTRACT_VERSION:
        raise TopicError("unsupported contract version")
    device_id = parts[2]
    if not is_valid_device_id(device_id):
        raise TopicError("invalid device id")
    try:
        kind = MessageKind("/".join(parts[3:]))
    except ValueError:
        raise TopicError("unknown message kind") from None
    return ParsedTopic(device_id=device_id, kind=kind)


def topic_matches(subscription: str, topic: str) -> bool:
    """MQTT wildcard matching (+ and #); used to verify subscriptions cover every kind."""
    sub, top = subscription.split("/"), topic.split("/")
    for i, part in enumerate(sub):
        if part == "#":
            return True
        if i >= len(top) or (part != "+" and part != top[i]):
            return False
    return len(sub) == len(top)
