from datetime import timedelta

import pytest

from gossy.contracts.messages import SCHEMA_IDS
from gossy.contracts.topics import MessageKind
from gossy.ingest.validation import RejectedMessage, parse_message
from tests.conftest import NOW, as_bytes, envelope

TOPIC = "bollbot/v1/sim-0001/telemetry"
LIMITS = {"now": NOW, "max_payload_bytes": 4096, "max_future_skew": timedelta(minutes=5)}


def telemetry(**overrides):
    return as_bytes(envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "sim-0001", {"batteryPct": 80}, **overrides))


def reason_of(topic, payload):
    with pytest.raises(RejectedMessage) as exc:
        parse_message(topic, payload, **LIMITS)
    return exc.value.reason


def test_accepts_valid_message():
    msg = parse_message(TOPIC, telemetry(), **LIMITS)
    assert msg.kind is MessageKind.TELEMETRY and msg.envelope.data.battery_pct == 80


def test_rejects_oversized_payload():
    assert reason_of(TOPIC, b"x" * 5000) == "payload_too_large"


def test_rejects_unknown_topic():
    assert reason_of("bollbot/v1/sim-0001/command", telemetry()) == "invalid_topic"


@pytest.mark.parametrize("payload", [b"not json", b"\xff\xfe", b"[]", b"{}"])
def test_rejects_malformed_payload(payload):
    assert reason_of(TOPIC, payload) == "schema_validation_failed"


def test_rejects_schema_for_other_kind():
    assert reason_of(TOPIC, telemetry(schema=SCHEMA_IDS[MessageKind.STATUS])) == "schema_mismatch"


def test_rejects_device_id_not_matching_topic():
    # The broker binds the topic deviceId to the authenticated username; a payload claiming
    # another device must not be accepted.
    assert reason_of(TOPIC, telemetry(deviceId="sim-0002")) == "device_id_mismatch"


def test_rejects_timestamp_far_in_future():
    assert reason_of(TOPIC, telemetry(ts=(NOW + timedelta(minutes=10)).isoformat())) == "timestamp_in_future"


def test_accepts_old_timestamp_for_offline_replay():
    msg = parse_message(TOPIC, telemetry(ts=(NOW - timedelta(days=3)).isoformat()), **LIMITS)
    assert msg.envelope.ts < NOW


def test_detail_never_echoes_input_values():
    with pytest.raises(RejectedMessage) as exc:
        parse_message(TOPIC, as_bytes(envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "sim-0001", {"batteryPct": "SECRET-VALUE"})), **LIMITS)
    assert "SECRET-VALUE" not in (exc.value.detail or "")
