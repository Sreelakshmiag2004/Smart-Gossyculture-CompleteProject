"""LOCAL REHEARSAL ONLY (disposable data): measure the broker's queue behaviour.

Runs inside the rehearsal ``tests`` container (see queue-overflow.sh):

    python - publish <base-seq> <count> [timeout-s]  # QoS 1 telemetry as sim-0002, seq = base ..
    python - report  <base-seq> <count>              # which of those seq values reached the database

``publish`` prints what the DEVICE sees: the PUBACK reason code of every message, and how long
each block of 500 acknowledgements took. A device deletes a message from its own queue when it
gets a PUBACK, so a PUBACK for a message the broker then drops is a silent loss.
"""

from __future__ import annotations

import asyncio
import collections
import json
import sys
import threading
import time

import paho.mqtt.client as paho
from paho.mqtt.enums import CallbackAPIVersion
from sqlalchemy import text

from gossy.config import DatabaseSettings
from gossy.db.engine import create_engine
from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import MQTT_HOST, MQTT_PORT, TEST_DEVICE, password, tls

BLOCK = 500


def publish(base: int, count: int, timeout: float) -> None:
    device = SimulatedDevice(TEST_DEVICE, start_seq=base)
    client = paho.Client(CallbackAPIVersion.VERSION2, client_id="rehearsal-queue-overflow", protocol=paho.MQTTv5)
    client.username_pw_set(TEST_DEVICE, password(TEST_DEVICE))
    client.tls_set_context(tls())
    client.max_inflight_messages_set(100)
    client.max_queued_messages_set(0)
    codes: collections.Counter[str] = collections.Counter()
    first_by_code: dict[str, int] = {}
    seq_of_mid: dict[int, int] = {}
    block_seconds: list[float] = []
    done = threading.Event()
    connected = threading.Event()
    acked = 0
    block_started = started = time.monotonic()

    def on_publish(_client, _userdata, mid, reason_code, _properties):
        nonlocal acked, block_started
        key = f"{reason_code.value} {reason_code}"
        codes[key] += 1
        first_by_code.setdefault(key, seq_of_mid.get(mid, base - 1) - base)
        acked += 1
        if acked % BLOCK == 0:
            now = time.monotonic()
            block_seconds.append(round(now - block_started, 1))
            block_started = now
        if acked == count:
            done.set()

    client.on_publish = on_publish
    client.on_connect = lambda *_: connected.set()
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
    client.loop_start()
    assert connected.wait(15), "no CONNACK"
    block_started = started = time.monotonic()
    for i in range(count):
        message = device.telemetry()
        info = client.publish(message.topic, message.payload, qos=1)
        seq_of_mid[info.mid] = base + i
    finished = done.wait(timeout)
    seconds = time.monotonic() - started
    client.disconnect()
    client.loop_stop()
    print(json.dumps({
        "published": count, "pubacks": acked, "all_pubacks_received": finished, "seconds": round(seconds, 1),
        "payload_bytes": len(message.payload), "puback_reason_codes": dict(codes), "first_offset_per_code": first_by_code,
        f"seconds_per_{BLOCK}_pubacks": block_seconds,
        "messages_per_second_first_and_last_block": [round(BLOCK / block_seconds[0], 1), round(BLOCK / block_seconds[-1], 1)] if block_seconds else None,
    }))


async def report(base: int, count: int) -> None:
    engine = create_engine(DatabaseSettings())
    try:
        async with engine.connect() as conn:
            rows = (await conn.execute(
                text("SELECT seq FROM ingested_messages WHERE device_id = :d AND seq >= :lo AND seq < :hi ORDER BY seq"),
                {"d": TEST_DEVICE, "lo": base, "hi": base + count},
            )).scalars().all()
    finally:
        await engine.dispose()
    stored = [s - base for s in rows]
    missing = sorted(set(range(count)) - set(stored))
    print(json.dumps({
        "published": count, "stored": len(stored), "lost": len(missing), "duplicates": len(stored) - len(set(stored)),
        "stored_offsets": f"{stored[0]}..{stored[-1]}" if stored else None,
        "lost_offsets": f"{missing[0]}..{missing[-1]}" if missing else None,
        "lost_is_one_contiguous_tail": bool(missing) and missing == list(range(missing[0], count)),
    }))


if __name__ == "__main__":
    command, base, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if command == "publish":
        publish(base, count, float(sys.argv[4]) if len(sys.argv) > 4 else 600.0)
    else:
        asyncio.run(report(base, count))
