import json

import pytest
from pydantic import ValidationError

from gossy.contracts.messages import ENVELOPE_MODELS, SCHEMA_IDS
from gossy.contracts.topics import MessageKind
from tests.conftest import as_bytes, envelope

VALID_DATA = {
    MessageKind.TELEMETRY: {"batteryPct": 87.5, "moistureRhPct": 41.2, "airTempC": 31.0, "bollsHarvestedTotal": 12, "solarActive": True},
    MessageKind.PEST: {"label": "bollworm", "confidence": 0.91, "bbox": [0.1, 0.2, 0.1, 0.1]},
    MessageKind.SPRAY: {"durationMs": 1500},
    MessageKind.HARVEST: {"maturity": "mature", "picked": True},
    MessageKind.SCAN: {"row": 3, "segment": 2, "counts": {"bollOpen": 27, "bollClosed": 41}, "startedAt": "2026-09-29T11:58:00+00:00", "frames": 120, "model": "yolov8n-416-v1", "airRhPct": 55.0},
    MessageKind.PICK: {"attemptId": "p-1a2b3c", "result": "completed", "row": 3, "segment": 2, "cycleS": 12.4, "outcome": "picked"},
    MessageKind.STATUS: {"state": "online"},
}


def validate(kind, env):
    return ENVELOPE_MODELS[kind].model_validate_json(as_bytes(env))


@pytest.mark.parametrize("kind", list(MessageKind))
def test_valid_message_per_kind(kind):
    parsed = validate(kind, envelope(SCHEMA_IDS[kind], "sim-0001", VALID_DATA[kind]))
    assert parsed.device_id == "sim-0001"
    assert parsed.ts.tzinfo is not None


def test_telemetry_minimal_only_battery_required():
    parsed = validate(MessageKind.TELEMETRY, envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "sim-0001", {"batteryPct": 50}))
    assert parsed.data.battery_pct == 50 and parsed.data.moisture_rh_pct is None


def test_envelope_rejects_unknown_keys():
    env = envelope(SCHEMA_IDS[MessageKind.STATUS], "sim-0001", {"state": "online"}, command="reboot")
    with pytest.raises(ValidationError):
        validate(MessageKind.STATUS, env)


def test_data_ignores_unknown_keys_for_forward_compatibility():
    data = {**VALID_DATA[MessageKind.STATUS], "firmware": "1.2.3"}
    assert validate(MessageKind.STATUS, envelope(SCHEMA_IDS[MessageKind.STATUS], "sim-0001", data)).data.state == "online"


@pytest.mark.parametrize(
    "kind,data",
    [
        (MessageKind.TELEMETRY, {"batteryPct": "87"}),  # strict: no string -> number coercion
        (MessageKind.TELEMETRY, {"batteryPct": 101}),
        (MessageKind.TELEMETRY, {"batteryPct": 50, "airTempC": 120}),
        (MessageKind.TELEMETRY, {}),
        (MessageKind.PEST, {"label": "Bollworm!", "confidence": 0.5}),
        (MessageKind.PEST, {"label": "bollworm", "confidence": 1.5}),
        (MessageKind.PEST, {"label": "bollworm", "confidence": 0.5, "bbox": [0.1, 0.2, 1.3, 0.1]}),
        (MessageKind.PEST, {"label": "bollworm", "confidence": 0.5, "bbox": [0.1, 0.2]}),
        (MessageKind.SPRAY, {"durationMs": 0}),
        (MessageKind.SPRAY, {"durationMs": 1000, "relatedMsgId": "not-a-ulid"}),
        (MessageKind.HARVEST, {"maturity": "ripe", "picked": True}),
        (MessageKind.SPRAY, {"durationMs": 0, "completed": True}),       # a spray that ran cannot last 0 ms
        (MessageKind.SCAN, {"row": 0, "segment": 1, "counts": {}, "startedAt": "2026-09-29T11:58:00+00:00", "frames": 1, "model": "m"}),
        (MessageKind.SCAN, {"row": 1, "segment": 1, "counts": {"bollOpen": -1}, "startedAt": "2026-09-29T11:58:00+00:00", "frames": 1, "model": "m"}),
        (MessageKind.SCAN, {"row": 1, "segment": 1, "counts": {}, "startedAt": "2026-09-29T11:58:00", "frames": 1, "model": "m"}),
        (MessageKind.SCAN, {"row": 1, "segment": 1, "counts": {"bollOpen": "3"}, "startedAt": "2026-09-29T11:58:00+00:00", "frames": 1, "model": "m"}),
        (MessageKind.PICK, {"attemptId": "p-1", "result": "success"}),
        (MessageKind.PICK, {"attemptId": "P 1", "result": "completed"}),
        (MessageKind.PICK, {"attemptId": "p-1", "result": "completed", "outcome": "great"}),
        (MessageKind.STATUS, {"state": "rebooting"}),
    ],
)
def test_invalid_data_rejected(kind, data):
    with pytest.raises(ValidationError):
        validate(kind, envelope(SCHEMA_IDS[kind], "sim-0001", data))


@pytest.mark.parametrize(
    "override",
    [
        {"ts": "2026-09-29T12:00:00"},  # naive timestamp
        {"seq": -1},
        {"seq": "1"},
        {"msgId": "abc"},
        {"deviceId": "svc-ingest"},
    ],
)
def test_invalid_envelope_rejected(override):
    env = envelope(SCHEMA_IDS[MessageKind.STATUS], "sim-0001", {"state": "online"}, **override)
    with pytest.raises(ValidationError):
        validate(MessageKind.STATUS, env)


def test_wire_format_is_camel_case():
    parsed = validate(MessageKind.TELEMETRY, envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "sim-0001", VALID_DATA[MessageKind.TELEMETRY]))
    dumped = json.loads(parsed.model_dump_json(by_alias=True))
    assert set(dumped) == {"schema", "msgId", "deviceId", "seq", "ts", "data"}
    assert "batteryPct" in dumped["data"]


# ---- Phase II additions -------------------------------------------------------------------
def test_telemetry_battery_optional_but_not_empty():
    env = envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "cart01", {"airTempC": 30.5, "airRhPct": 61.0, "dewpointC": 22.3})
    parsed = validate(MessageKind.TELEMETRY, env)
    assert parsed.data.battery_pct is None and parsed.data.air_rh_pct == 61.0
    with pytest.raises(ValidationError):  # still at least one reading
        validate(MessageKind.TELEMETRY, envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "cart01", {}))


def test_spray_not_run_may_report_zero_duration():
    data = {"durationMs": 0, "completed": False, "reason": "person_side", "mlRequested": 27.0, "mlDelivered": 0.0}
    parsed = validate(MessageKind.SPRAY, envelope(SCHEMA_IDS[MessageKind.SPRAY], "cart01", data))
    assert parsed.data.completed is False and parsed.data.reason == "person_side"


def test_scan_counts_default_to_zero_and_round_trip_camel_case():
    parsed = validate(MessageKind.SCAN, envelope(SCHEMA_IDS[MessageKind.SCAN], "cart01", VALID_DATA[MessageKind.SCAN]))
    assert parsed.data.counts.boll_open == 27 and parsed.data.counts.mealybug_colony == 0
    dumped = json.loads(parsed.model_dump_json(by_alias=True, exclude_none=True))
    assert dumped["data"]["counts"]["bollOpen"] == 27 and dumped["data"]["startedAt"]


def test_pick_minimal():
    parsed = validate(MessageKind.PICK, envelope(SCHEMA_IDS[MessageKind.PICK], "cart01", {"attemptId": "p-9", "result": "unreachable", "reason": "joint limits"}))
    assert parsed.data.outcome is None and parsed.data.result == "unreachable"


def test_cart_health_readings_count_as_readings():
    parsed = validate(MessageKind.TELEMETRY, envelope(SCHEMA_IDS[MessageKind.TELEMETRY], "cart01", {"fps": 4.2, "outboxPending": 0}))
    assert parsed.data.fps == 4.2 and parsed.data.outbox_pending == 0
