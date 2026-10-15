import pytest
"""End to end: simulator → Mosquitto (TLS) → ingest service → PostgreSQL/TimescaleDB."""

import json

import httpx
from sqlalchemy import bindparam, text

from gossy.contracts.messages import SCHEMA_IDS
from gossy.contracts.topics import MessageKind, topic_for
from gossy.ids import new_ulid
from gossy_sim.device import SimulatedDevice
from gossy_sim.publisher import BrokerConfig, connect, publish_all
from tests.integration.conftest import MQTT_HOST, MQTT_PORT, TEST_DEVICE, PahoSession, password, tls, wait_for

pytestmark = pytest.mark.integration


def broker() -> BrokerConfig:
    return BrokerConfig(MQTT_HOST, MQTT_PORT, TEST_DEVICE, password(TEST_DEVICE), tls())


async def count(engine, sql, **params):
    stmt = text(sql)
    if "ids" in params:
        stmt = stmt.bindparams(bindparam("ids", expanding=True))
    async with engine.connect() as conn:
        return (await conn.execute(stmt, params)).scalar()


async def ingest_stats(ingest_url):
    async with httpx.AsyncClient(base_url=ingest_url, timeout=5) as c:
        return (await c.get("/readyz")).json()["info"]["ingest"]


async def test_simulator_messages_are_ingested(engine):
    device = SimulatedDevice(TEST_DEVICE)
    pest = device.pest()
    messages = [device.status("online"), device.telemetry(), device.telemetry(), device.telemetry(), pest, device.spray(related_msg_id=pest.msg_id), device.harvest()]
    async with connect(device, broker(), will=False) as client:
        await publish_all(client, messages)
    ids = [m.msg_id for m in messages]

    async def all_ingested():
        return await count(engine, "SELECT count(*) FROM ingested_messages WHERE msg_id IN :ids", ids=ids) == len(ids)

    await wait_for(all_ingested)
    assert await count(engine, "SELECT count(*) FROM telemetry WHERE msg_id IN :ids", ids=ids) == 3
    async with engine.connect() as conn:
        types = set((await conn.execute(text("SELECT event_type FROM device_events WHERE msg_id IN :ids").bindparams(bindparam("ids", expanding=True)), {"ids": ids})).scalars())
        status = (await conn.execute(text("SELECT state, last_seen_at FROM device_status WHERE device_id = :d"), {"d": TEST_DEVICE})).one()
        spray = (await conn.execute(text("SELECT data FROM device_events WHERE msg_id = :m"), {"m": messages[5].msg_id})).scalar()
    assert types == {"pest", "spray", "harvest"}
    assert status.state == "online" and status.last_seen_at is not None
    assert spray["relatedMsgId"] == pest.msg_id


async def test_duplicate_deliveries_are_stored_once(engine, ingest_url):
    device = SimulatedDevice(TEST_DEVICE)
    message = device.telemetry()
    before = await ingest_stats(ingest_url)
    async with connect(device, broker(), will=False) as client:
        await publish_all(client, [message, message, message])

    async def processed_all():
        return (await ingest_stats(ingest_url))["duplicates"] >= before["duplicates"] + 2

    await wait_for(processed_all)
    assert await count(engine, "SELECT count(*) FROM ingested_messages WHERE msg_id = :m", m=message.msg_id) == 1
    assert await count(engine, "SELECT count(*) FROM telemetry WHERE msg_id = :m", m=message.msg_id) == 1


async def test_invalid_message_is_rejected_and_recorded(engine, ingest_url):
    marker = new_ulid()
    bad = {  # claims to be another device: must never be stored as data
        "schema": SCHEMA_IDS[MessageKind.TELEMETRY], "msgId": marker, "deviceId": "sim-0001",
        "seq": 0, "ts": "2026-09-29T12:00:00+00:00", "data": {"batteryPct": 50},
    }
    before = await ingest_stats(ingest_url)
    async with connect(SimulatedDevice(TEST_DEVICE), broker(), will=False) as client:
        await client.publish(topic_for(TEST_DEVICE, MessageKind.TELEMETRY), json.dumps(bad).encode(), qos=1)

    async def rejected():
        return await count(engine, "SELECT count(*) FROM rejected_messages WHERE reason = 'device_id_mismatch' AND payload_excerpt LIKE :p", p=f"%{marker}%") == 1

    await wait_for(rejected)
    assert await count(engine, "SELECT count(*) FROM ingested_messages WHERE msg_id = :m", m=marker) == 0
    assert (await ingest_stats(ingest_url))["rejected"] >= before["rejected"] + 1


async def test_last_will_marks_device_offline(engine):
    device = SimulatedDevice(TEST_DEVICE)
    will = device.last_will()
    online = device.status("online")
    session = PahoSession(TEST_DEVICE, "itest-lwt", will=(will.topic, will.payload))
    session.__enter__()
    session.publish(online.topic, online.payload, retain=True)

    async def is_state(state):
        async with engine.connect() as conn:
            return (await conn.execute(text("SELECT state FROM device_status WHERE device_id = :d"), {"d": TEST_DEVICE})).scalar() == state

    await wait_for(lambda: is_state("online"))
    session.drop_connection()  # ungraceful: broker must publish the Last Will
    await wait_for(lambda: is_state("offline"))
    assert await count(engine, "SELECT count(*) FROM ingested_messages WHERE msg_id = :m", m=will.msg_id) == 1
