"""Persisted telemetry, device events and detections through the REST API: retrieval, filtering,
time ranges, pagination, validation and authorization."""

import json
import random
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import text

from gossy.contracts.messages import SCHEMA_IDS
from gossy.contracts.topics import MessageKind, topic_for
from gossy.ids import new_ulid
from gossy_sim.device import OutgoingMessage, SimulatedDevice
from tests.integration.conftest import FARMER_A, FARMER_B, TEST_DEVICE, bearer, login, own_device, publish_as_test_device, wait_for, wait_ingested

pytestmark = pytest.mark.integration


class Clock:
    """Device clock pinned to a unique past window so time-range assertions are deterministic."""

    def __init__(self):
        self.t = datetime.now(UTC).replace(microsecond=0) - timedelta(days=2, seconds=random.randint(0, 86_400))
        self.base = self.t

    def __call__(self):
        return self.t

    def advance(self, seconds=1):
        self.t += timedelta(seconds=seconds)


def iso(dt: datetime) -> str:
    return dt.isoformat()


@pytest.fixture
async def setup(api, engine):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    clock = Clock()
    device = SimulatedDevice(TEST_DEVICE, clock=clock)
    telemetry = []
    for _ in range(3):
        telemetry.append(device.telemetry())
        clock.advance()
    pest = device.pest()
    clock.advance()
    spray = device.spray(related_msg_id=pest.msg_id)
    clock.advance()
    harvest = device.harvest()
    clock.advance()
    messages = [*telemetry, pest, spray, harvest]
    await publish_as_test_device(messages)
    await wait_ingested(engine, [m.msg_id for m in messages])
    window = {"from": iso(clock.base), "to": iso(clock.t)}
    return {"a": a, "clock": clock, "telemetry": telemetry, "pest": pest, "spray": spray, "harvest": harvest, "window": window}


def data(message: OutgoingMessage) -> dict:
    return json.loads(message.payload)["data"]


async def test_telemetry_retrieval_matches_persisted_values(api, setup):
    r = await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params=setup["window"], headers=bearer(setup["a"]))
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert [i["msgId"] for i in items] == [m.msg_id for m in reversed(setup["telemetry"])]  # newest first
    first, sent = items[-1], data(setup["telemetry"][0])
    assert first["batteryPct"] == sent["batteryPct"] and first["moistureRhPct"] == sent["moistureRhPct"]
    assert first["airTempC"] == sent["airTempC"] and first["solarActive"] == sent["solarActive"]
    assert first["bollsHarvestedTotal"] == sent["bollsHarvestedTotal"]
    assert r.json()["nextCursor"] is None


async def test_telemetry_carries_the_backend_receipt_time(api, engine, setup):
    """Phase 5A: receivedAt is when the backend stored the reading - the value the live event
    carries for the same msgId - and has nothing to do with the device's own timestamp."""
    before = datetime.now(UTC)
    r = await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params=setup["window"], headers=bearer(setup["a"]))
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert len(items) == 3
    async with engine.connect() as conn:
        ledger = {row.msg_id: row.received_at for row in await conn.execute(text("SELECT msg_id, received_at FROM ingested_messages WHERE device_id = :d"), {"d": TEST_DEVICE})}
    for item in items:
        received = datetime.fromisoformat(item["receivedAt"])
        assert received.tzinfo is not None
        assert received == ledger[item["msgId"]], "the ledger's receipt time, i.e. receivedAt of the live event"
        # the device clock of this test is two days in the past; the receipt time is now
        assert datetime.fromisoformat(item["time"]) < received - timedelta(days=1)
        assert before - timedelta(minutes=2) < received <= before
    # the same row through a single-item page (what the dashboard requests)
    newest = (await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params={**setup["window"], "limit": 1}, headers=bearer(setup["a"]))).json()["items"][0]
    assert newest["msgId"] == setup["telemetry"][-1].msg_id and newest["receivedAt"] == items[0]["receivedAt"]


async def test_live_event_and_rest_report_the_same_receipt_time(api, engine):
    from tests.integration.conftest import ws_connect, ws_recv, ws_recv_until

    a = await login(api, FARMER_A)
    await own_device(api, a)
    device = SimulatedDevice(TEST_DEVICE)
    async with ws_connect(a) as ws:
        assert (await ws_recv(ws))["type"] == "hello"
        await ws.send(json.dumps({"op": "start"}))
        await ws_recv_until(ws, lambda m: m["type"] == "resumed")
        message = device.telemetry()
        await publish_as_test_device([message])
        event, _ = await ws_recv_until(ws, lambda m: m["type"] == "event" and m["msgId"] == message.msg_id)
    row = (await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params={"limit": 1}, headers=bearer(a))).json()["items"][0]
    assert row["msgId"] == message.msg_id
    assert datetime.fromisoformat(row["receivedAt"]) == datetime.fromisoformat(event["receivedAt"])


async def test_telemetry_time_range_is_inclusive_start_exclusive_end(api, setup):
    base = setup["clock"].base
    r = await api.get(
        f"/api/v1/devices/{TEST_DEVICE}/telemetry",
        params={"from": iso(base + timedelta(seconds=1)), "to": iso(base + timedelta(seconds=2))},
        headers=bearer(setup["a"]),
    )
    assert [i["msgId"] for i in r.json()["items"]] == [setup["telemetry"][1].msg_id]


async def test_telemetry_pagination_walks_every_item_once(api, setup):
    seen, cursor = [], None
    for _ in range(5):
        params = {**setup["window"], "limit": 1, **({"cursor": cursor} if cursor else {})}
        body = (await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params=params, headers=bearer(setup["a"]))).json()
        seen += [i["msgId"] for i in body["items"]]
        cursor = body["nextCursor"]
        if cursor is None:
            break
    assert seen == [m.msg_id for m in reversed(setup["telemetry"])]


@pytest.mark.parametrize(
    "params,code",
    [
        ({"limit": 0}, "validation_failed"),
        ({"limit": 1001}, "validation_failed"),
        ({"from": "2026-09-29T12:00:00"}, "validation_failed"),  # no timezone
        ({"from": "yesterday"}, "validation_failed"),
        ({"from": "2026-09-29T12:00:00+00:00", "to": "2026-09-29T11:00:00+00:00"}, "invalid_time_range"),
        ({"cursor": "not-a-cursor"}, "invalid_cursor"),
    ],
)
async def test_telemetry_query_validation(api, setup, params, code):
    r = await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params=params, headers=bearer(setup["a"]))
    assert r.status_code == 422 and r.json()["error"]["code"] == code, r.text


async def test_events_filter_by_type(api, setup):
    url = f"/api/v1/devices/{TEST_DEVICE}/events"
    all_items = (await api.get(url, params=setup["window"], headers=bearer(setup["a"]))).json()["items"]
    assert [(i["type"], i["msgId"]) for i in all_items] == [("harvest", setup["harvest"].msg_id), ("spray", setup["spray"].msg_id), ("pest", setup["pest"].msg_id)]
    only = (await api.get(url, params={**setup["window"], "type": "spray"}, headers=bearer(setup["a"]))).json()["items"]
    assert [i["msgId"] for i in only] == [setup["spray"].msg_id] and only[0]["data"]["relatedMsgId"] == setup["pest"].msg_id
    two = (await api.get(url, params=[*setup["window"].items(), ("type", "pest"), ("type", "harvest")], headers=bearer(setup["a"]))).json()["items"]
    assert {i["type"] for i in two} == {"pest", "harvest"}
    assert (await api.get(url, params={"type": "command"}, headers=bearer(setup["a"]))).status_code == 422


async def test_other_farmer_cannot_read_telemetry_events_or_detections(api, setup):
    b = await login(api, FARMER_B)
    for path in (f"/api/v1/devices/{TEST_DEVICE}/telemetry", f"/api/v1/devices/{TEST_DEVICE}/events"):
        r = await api.get(path, headers=bearer(b))
        assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"
    assert (await api.get("/api/v1/detections", params={"deviceId": TEST_DEVICE}, headers=bearer(b))).status_code == 404
    unscoped = (await api.get("/api/v1/detections", params=setup["window"], headers=bearer(b))).json()["items"]
    assert setup["pest"].msg_id not in [d["id"] for d in unscoped]


async def test_telemetry_requires_authentication(api):
    assert (await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry")).status_code == 401
    assert (await api.get("/api/v1/detections")).status_code == 401


# --------------------------------------------------------------------------- detections

async def test_detection_ingested_from_device_is_retrievable(api, setup):
    r = await api.get("/api/v1/detections", params={**setup["window"], "deviceId": TEST_DEVICE}, headers=bearer(setup["a"]))
    assert r.status_code == 200, r.text
    items = r.json()["items"]
    assert len(items) == 1
    det, sent = items[0], data(setup["pest"])
    assert det["id"] == setup["pest"].msg_id and det["deviceId"] == TEST_DEVICE
    assert det["label"] == sent["label"] and det["confidence"] == sent["confidence"] and det["bbox"] == sent["bbox"]
    assert det["source"] == "upstream_device_detector"
    assert det["detectedAt"].startswith(setup["clock"].base.strftime("%Y-%m-%dT%H:%M"))
    # Unscoped query returns detections of all the caller's devices.
    unscoped = (await api.get("/api/v1/detections", params=setup["window"], headers=bearer(setup["a"]))).json()["items"]
    assert [d["id"] for d in unscoped] == [setup["pest"].msg_id]


async def test_detection_filters(api, setup):
    sent = data(setup["pest"])
    common = {**setup["window"], "deviceId": TEST_DEVICE}
    get = lambda **p: api.get("/api/v1/detections", params={**common, **p}, headers=bearer(setup["a"]))  # noqa: E731
    assert len((await get(label=sent["label"])).json()["items"]) == 1
    assert (await get(label="no_such_label")).json()["items"] == []
    assert len((await get(minConfidence=sent["confidence"])).json()["items"]) == 1
    assert (await get(minConfidence=min(1.0, sent["confidence"] + 0.001))).json()["items"] == []


@pytest.mark.parametrize("params", [{"minConfidence": 1.5}, {"minConfidence": -0.1}, {"label": "Bad Label"}, {"label": "x" * 65}])
async def test_detection_query_validation(api, params):
    a = await login(api, FARMER_A)
    r = await api.get("/api/v1/detections", params=params, headers=bearer(a))
    assert r.status_code == 422 and r.json()["error"]["code"] == "validation_failed"


async def test_invalid_detection_payload_is_rejected_not_stored(api, engine):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    marker = new_ulid()
    bad = {
        "schema": SCHEMA_IDS[MessageKind.PEST], "msgId": marker, "deviceId": TEST_DEVICE, "seq": 1,
        "ts": datetime.now(UTC).isoformat(), "data": {"label": "bollworm", "confidence": 1.5},
    }
    await publish_as_test_device([OutgoingMessage(topic_for(TEST_DEVICE, MessageKind.PEST), json.dumps(bad).encode(), marker, MessageKind.PEST)])

    async def rejected():
        async with engine.connect() as conn:
            return (await conn.execute(text("SELECT count(*) FROM rejected_messages WHERE payload_excerpt LIKE :p"), {"p": f"%{marker}%"})).scalar() == 1

    await wait_for(rejected)
    async with engine.connect() as conn:
        reason = (await conn.execute(text("SELECT reason FROM rejected_messages WHERE payload_excerpt LIKE :p"), {"p": f"%{marker}%"})).scalar()
    assert reason == "schema_validation_failed"
    items = (await api.get("/api/v1/detections", params={"deviceId": TEST_DEVICE, "limit": 1000}, headers=bearer(a))).json()["items"]
    assert marker not in [d["id"] for d in items]
