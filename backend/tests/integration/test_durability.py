"""Phase 2.5 durability: crash injection and duplicate/out-of-order delivery.

Crash tests arm a fault for one message (gossy.ingest.faults). The ingest process then exits
with os._exit at that exact point - no PUBACK, no commit, no cleanup - and Docker's restart
policy restarts it. Recovery uses only the production path: the broker redelivers every
unacknowledged message to the persistent session and the msgId ledger deduplicates.

Every test checks, per message: the ledger row exists exactly once, the typed row (telemetry or
device event = detection) exists exactly once, and alerts exist exactly as many times as the
alert rules produce (never duplicated).
"""

import asyncio
import json
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path

import aiomqtt
import pytest
from sqlalchemy import bindparam, text

from gossy.contracts.topics import MessageKind
from gossy.ids import new_ulid
from gossy.ingest.faults import AFTER_COMMIT, BEFORE_TRANSACTION, DURING_TRANSACTION
from gossy_sim.device import OutgoingMessage, SimulatedDevice
from tests.integration.conftest import FARMER_A, MQTT_HOST, MQTT_PORT, TEST_DEVICE, bearer, login, own_device, password, publish_as_test_device, tls, wait_for

pytestmark = pytest.mark.integration

FAULT_DIR = Path(os.environ.get("GOSSY_TEST_FAULT_DIR", "/run/gossy-faults"))
# alerts produced per message kind by gossy.alerts.rules
ALERTS = {MessageKind.TELEMETRY: 0, MessageKind.PEST: 1, MessageKind.SPRAY: 1, MessageKind.HARVEST: 0}
RECOVERY_TIMEOUT = 90.0  # includes Docker restarting the crashed ingest process


async def effects(engine, msg_ids: list[str]) -> dict[str, dict[str, int]]:
    queries = {
        "ledger": "SELECT msg_id, count(*) FROM ingested_messages WHERE msg_id IN :ids GROUP BY msg_id",
        "telemetry": "SELECT msg_id, count(*) FROM telemetry WHERE msg_id IN :ids GROUP BY msg_id",
        "events": "SELECT msg_id, count(*) FROM device_events WHERE msg_id IN :ids GROUP BY msg_id",
        "alerts": "SELECT source_msg_id, count(*) FROM alerts WHERE source_msg_id IN :ids GROUP BY source_msg_id",
        "dead_letters": "SELECT substring(payload_excerpt from '\"msgId\":\"([0-9A-Z]{26})\"'), count(*) FROM rejected_messages WHERE reason = 'processing_failed' AND substring(payload_excerpt from '\"msgId\":\"([0-9A-Z]{26})\"') IN :ids GROUP BY 1",
    }
    out = {}
    async with engine.connect() as conn:
        for name, sql in queries.items():
            rows = await conn.execute(text(sql).bindparams(bindparam("ids", expanding=True)), {"ids": msg_ids})
            out[name] = {r[0]: r[1] for r in rows}
    return out


def expected(messages: list[OutgoingMessage]) -> dict[str, dict[str, int]]:
    exp = {"ledger": {}, "telemetry": {}, "events": {}, "alerts": {}, "dead_letters": {}}
    for m in messages:
        exp["ledger"][m.msg_id] = 1
        if m.kind is MessageKind.TELEMETRY:
            exp["telemetry"][m.msg_id] = 1
        elif m.kind is not MessageKind.STATUS:
            exp["events"][m.msg_id] = 1
        if ALERTS.get(m.kind):
            exp["alerts"][m.msg_id] = ALERTS[m.kind]
    return exp


async def assert_exactly_once(engine, messages: list[OutgoingMessage], timeout: float = RECOVERY_TIMEOUT):
    """Eventually every message has exactly its expected effects - no loss, no duplicates."""
    ids = [m.msg_id for m in {m.msg_id: m for m in messages}.values()]
    want = expected(list({m.msg_id: m for m in messages}.values()))
    last = {}

    async def done():
        nonlocal last
        last = await effects(engine, ids)
        return last["ledger"] == want["ledger"]

    try:
        await wait_for(done, timeout=timeout, interval=0.5)
    except AssertionError:
        raise AssertionError(f"not all messages ingested: missing={set(ids) - set(last.get('ledger', {}))}") from None
    await asyncio.sleep(1.0)  # let any (wrong) duplicate processing surface
    assert await effects(engine, ids) == want


def arm(msg_id: str, point: str) -> Path:
    FAULT_DIR.mkdir(parents=True, exist_ok=True)
    (FAULT_DIR / msg_id).write_text(point)
    return FAULT_DIR / f"{msg_id}.fired"


async def crash_scenario(api, engine, point: str):
    if not os.environ.get("GOSSY_TEST_FAULT_DIR"):
        pytest.skip("failure injection is development/test only (refused in staging/production)")
    a = await login(api, FARMER_A)
    await own_device(api, a)
    device = SimulatedDevice(TEST_DEVICE)
    victim = device.pest()  # pest: ledger + device event (detection) + alert
    followers = [device.telemetry(), device.spray(related_msg_id=victim.msg_id), device.telemetry(), device.harvest()]
    fired = arm(victim.msg_id, point)
    await publish_as_test_device([victim, *followers])

    async def crashed():
        return fired.exists()  # renamed immediately before os._exit at that exact point

    await wait_for(crashed, timeout=30)
    await assert_exactly_once(engine, [victim, *followers])
    # API view: exactly one detection and one pest alert for the victim.
    detections = (await api.get("/api/v1/detections", params={"deviceId": TEST_DEVICE, "limit": 1000}, headers=bearer(a))).json()["items"]
    assert [d["id"] for d in detections].count(victim.msg_id) == 1
    alerts = (await api.get("/api/v1/alerts", params={"deviceId": TEST_DEVICE, "limit": 1000}, headers=bearer(a))).json()["items"]
    assert [x["sourceMsgId"] for x in alerts].count(victim.msg_id) == 1


# --------------------------------------------------------------------------- A, B, C

async def test_A_crash_before_database_transaction(api, engine):
    await crash_scenario(api, engine, BEFORE_TRANSACTION)


async def test_B_crash_during_database_transaction(api, engine):
    await crash_scenario(api, engine, DURING_TRANSACTION)


async def test_C_crash_immediately_after_commit_before_puback(api, engine):
    # The message is committed but never acknowledged: the broker redelivers it and the ledger
    # must turn that redelivery into a duplicate with no second telemetry/event/alert row.
    await crash_scenario(api, engine, AFTER_COMMIT)


# --------------------------------------------------------------------------- H, I

async def test_H_duplicate_mqtt_delivery(engine):
    device = SimulatedDevice(TEST_DEVICE)
    pest, telemetry, spray = device.pest(), device.telemetry(), device.spray()
    await publish_as_test_device([pest, pest, telemetry, pest, telemetry, spray, spray])
    await assert_exactly_once(engine, [pest, telemetry, spray])


async def test_I_many_identical_messages_from_concurrent_connections(engine):
    device = SimulatedDevice(TEST_DEVICE)
    pest = device.pest()

    async def sender(client_suffix: str, copies: int):
        async with aiomqtt.Client(MQTT_HOST, MQTT_PORT, username=TEST_DEVICE, password=password(TEST_DEVICE), identifier=f"itest-identical-{client_suffix}",
                                  protocol=aiomqtt.ProtocolVersion.V5, tls_context=tls(), timeout=10) as client:
            for _ in range(copies):
                await client.publish(pest.topic, pest.payload, qos=1)

    await asyncio.gather(sender("a", 10), sender("b", 10), sender("c", 10))  # 30 identical copies
    await assert_exactly_once(engine, [pest])


async def test_I_identical_content_with_distinct_msg_ids_is_not_deduplicated(engine):
    # Idempotency is keyed on msgId (the device's identity for one observation), never on content.
    base = SimulatedDevice(TEST_DEVICE).telemetry()
    data = json.loads(base.payload)
    copies = []
    for i in range(5):
        env ={**data, "msgId": new_ulid(), "seq": data["seq"] + i}
        copies.append(OutgoingMessage(base.topic, json.dumps(env).encode(), env["msgId"], MessageKind.TELEMETRY))
    await publish_as_test_device(copies)
    await assert_exactly_once(engine, copies)


# --------------------------------------------------------------------------- J

async def test_J_out_of_order_messages(api, engine):
    """The contract allows late/out-of-order delivery (offline replay from the device queue):
    records are stored by device timestamp, seq gaps/reordering are accepted, last-seen never
    moves backwards, and a late message is not mistaken for a duplicate."""
    a = await login(api, FARMER_A)
    await own_device(api, a)
    now = datetime.now(UTC).replace(microsecond=0)
    clock_value = [now]
    device = SimulatedDevice(TEST_DEVICE, clock=lambda: clock_value[0], start_seq=1000)
    produced = []
    for minutes_ago in (30, 20, 10):  # produced oldest -> newest (seq 1000, 1001, 1002)
        clock_value[0] = now - timedelta(minutes=minutes_ago)
        produced.append(device.telemetry())
    clock_value[0] = now - timedelta(minutes=25)
    late_pest = device.pest()  # seq 1003 but older than two telemetry points
    delivery = [produced[2], late_pest, produced[0], produced[1]]  # newest first, then late ones
    await publish_as_test_device(delivery)
    await assert_exactly_once(engine, delivery)
    window = {"from": (now - timedelta(minutes=31)).isoformat(), "to": (now - timedelta(minutes=9)).isoformat(), "limit": 1000}
    items = (await api.get(f"/api/v1/devices/{TEST_DEVICE}/telemetry", params=window, headers=bearer(a))).json()["items"]
    mine = [i["msgId"] for i in items if i["msgId"] in {m.msg_id for m in produced}]
    assert mine == [produced[2].msg_id, produced[1].msg_id, produced[0].msg_id]  # device-time order
    async with engine.connect() as conn:
        seqs = dict((await conn.execute(text("SELECT msg_id, seq FROM ingested_messages WHERE msg_id IN :ids").bindparams(bindparam("ids", expanding=True)), {"ids": [m.msg_id for m in delivery]})).all())
        last_seen = (await conn.execute(text("SELECT last_seen_at FROM device_status WHERE device_id = :d"), {"d": TEST_DEVICE})).scalar()
    assert sorted(seqs.values()) == [1000, 1001, 1002, 1003]
    assert last_seen >= now - timedelta(seconds=5)  # receipt time; not moved back by old messages
