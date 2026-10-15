"""Integration fixtures. These tests run inside the dev Compose network (service ``tests``)."""

from __future__ import annotations

import asyncio
import os
import ssl
import threading
import time
from collections.abc import Awaitable, Callable
from pathlib import Path

import paho.mqtt.client as paho
import pytest
from paho.mqtt.enums import CallbackAPIVersion

from gossy.config import DatabaseSettings
from gossy.db.engine import create_engine
from gossy.mqtt.connection import build_tls_context

SECRETS = Path(os.environ.get("GOSSY_TEST_SECRETS_DIR", "/run/gossy-secrets"))
MQTT_HOST = os.environ.get("GOSSY_TEST_MQTT_HOST", "mosquitto")
MQTT_PORT = int(os.environ.get("GOSSY_TEST_MQTT_PORT", "8883"))
TEST_DEVICE = "sim-0002"  # sim-0001 is reserved for the long-running simulator service


def password(account: str) -> str:
    return (SECRETS / "mqtt" / f"{account}.password").read_text().strip()


def tls() -> ssl.SSLContext:
    return build_tls_context(SECRETS / "certs" / "ca.crt")


@pytest.fixture
def api_url() -> str:
    return os.environ.get("GOSSY_TEST_API_URL", "http://api:8000")


@pytest.fixture
def ingest_url() -> str:
    return os.environ.get("GOSSY_TEST_INGEST_URL", "http://ingest:8001")


@pytest.fixture
async def engine():
    eng = create_engine(DatabaseSettings())
    yield eng
    await eng.dispose()


async def wait_for(predicate: Callable[[], Awaitable[bool]], timeout: float = 20.0, interval: float = 0.25) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await predicate():
            return
        await asyncio.sleep(interval)
    raise AssertionError(f"condition not met within {timeout}s")


# --------------------------------------------------------------------------- Phase 2 API helpers
# Allow-listed TEST numbers (unassigned +999 range; see deploy/dev/compose.yaml).
FARMER_A = "+99900000001"
FARMER_B = "+99900000002"
FARMER_C = "+99900000003"
ADMIN = "+99900000009"
UNLISTED = "+99900000077"  # valid E.164, NOT allow-listed
WS_URL = os.environ.get("GOSSY_TEST_WS_URL", "ws://api:8000/api/v1/ws")


def test_otp_code() -> str:
    return (SECRETS / "auth" / "test-otp.code").read_text().strip()


test_otp_code.__test__ = False  # helper, not a test


@pytest.fixture
async def api(api_url):
    import httpx

    async with httpx.AsyncClient(base_url=api_url, timeout=10) as client:
        yield client


def bearer(tokens: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['accessToken']}"}


async def login(client, phone: str) -> dict:
    r = await client.post("/api/v1/auth/otp/request", json={"phone": phone})
    assert r.status_code == 202, r.text
    r = await client.post("/api/v1/auth/otp/verify", json={"phone": phone, "code": test_otp_code()})
    assert r.status_code == 200, r.text
    return r.json()


async def login_admin(client) -> dict:
    from gossy.manage import set_role

    await set_role(ADMIN, "admin")  # operator CLI path; there is no API to grant admin
    return await login(client, ADMIN)


async def own_device(client, owner: dict, device_id: str = TEST_DEVICE) -> str:
    """Register (if needed) and (re)attach ``device_id`` to a fresh farm of ``owner``. Returns farm id."""
    from gossy.ids import new_ulid

    admin = await login_admin(client)
    r = await client.post("/api/v1/admin/devices", json={"deviceId": device_id}, headers=bearer(admin))
    assert r.status_code in (201, 409), r.text
    r = await client.post(f"/api/v1/admin/devices/{device_id}/claim-code", headers=bearer(admin))
    assert r.status_code == 200, r.text
    code = r.json()["claimCode"]
    r = await client.post("/api/v1/farms", json={"name": f"itest farm {new_ulid()[-6:]}"}, headers=bearer(owner))
    assert r.status_code == 201, r.text
    farm_id = r.json()["id"]
    r = await client.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code, "farmId": farm_id}, headers=bearer(owner))
    assert r.status_code == 200, r.text
    return farm_id


async def publish_as_test_device(messages) -> None:
    """Publish OutgoingMessages over MQTT/TLS with the TEST_DEVICE broker credential."""
    from gossy_sim.device import SimulatedDevice
    from gossy_sim.publisher import BrokerConfig, connect, publish_all

    broker = BrokerConfig(MQTT_HOST, MQTT_PORT, TEST_DEVICE, password(TEST_DEVICE), tls())
    async with connect(SimulatedDevice(TEST_DEVICE), broker, will=False) as client:
        await publish_all(client, messages)


async def wait_ingested(engine, msg_ids: list[str]) -> None:
    from sqlalchemy import bindparam, text

    stmt = text("SELECT count(*) FROM ingested_messages WHERE msg_id IN :ids").bindparams(bindparam("ids", expanding=True))

    async def done():
        async with engine.connect() as conn:
            return (await conn.execute(stmt, {"ids": msg_ids})).scalar() == len(msg_ids)

    await wait_for(done)


def ws_connect(tokens: dict | None = None, token: str | None = None):
    """WebSocket client for /api/v1/ws with the access token in the Authorization header."""
    from websockets.asyncio.client import connect

    headers = {}
    if tokens is not None or token is not None:
        headers["Authorization"] = f"Bearer {token if token is not None else tokens['accessToken']}"
    return connect(WS_URL, additional_headers=headers, open_timeout=10, close_timeout=5)


async def ws_recv(ws, timeout: float = 10.0) -> dict:
    import json

    return json.loads(await asyncio.wait_for(ws.recv(), timeout))


async def ws_recv_until(ws, predicate, timeout: float = 15.0) -> tuple[dict, list[dict]]:
    """Receive until ``predicate(msg)``; returns (matching message, messages seen before it)."""
    deadline = time.monotonic() + timeout
    seen = []
    while True:
        msg = await ws_recv(ws, max(0.1, deadline - time.monotonic()))
        if predicate(msg):
            return msg, seen
        seen.append(msg)


class PahoSession:
    """Synchronous paho client used where MQTT v5 reason codes must be inspected."""

    def __init__(self, username: str, client_id: str, *, will: tuple[str, bytes] | None = None):
        self.client = paho.Client(CallbackAPIVersion.VERSION2, client_id=client_id, protocol=paho.MQTTv5)
        self.client.username_pw_set(username, password(username))
        self.client.tls_set_context(tls())
        if will:
            self.client.will_set(will[0], will[1], qos=1, retain=True)
        self._connected = threading.Event()
        self._acks: dict[int, object] = {}
        self._ack_event = threading.Condition()
        self.connect_reason = None
        self.received: list[paho.MQTTMessage] = []
        self.client.on_message = lambda client, userdata, message: self.received.append(message)
        self.client.on_connect = self._on_connect
        self.client.on_publish = self._on_publish
        self.client.on_subscribe = self._on_subscribe

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        self.connect_reason = reason_code
        self._connected.set()

    def _on_publish(self, client, userdata, mid, reason_code, properties):
        with self._ack_event:
            self._acks[mid] = reason_code
            self._ack_event.notify_all()

    def _on_subscribe(self, client, userdata, mid, reason_codes, properties):
        with self._ack_event:
            self._acks[mid] = reason_codes
            self._ack_event.notify_all()

    def __enter__(self):
        self.client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
        self.client.loop_start()
        assert self._connected.wait(10), "no CONNACK"
        return self

    def __exit__(self, *exc):
        self.client.disconnect()
        self.client.loop_stop()

    def _wait_ack(self, mid: int):
        with self._ack_event:
            assert self._ack_event.wait_for(lambda: mid in self._acks, timeout=10), "no ack"
            return self._acks[mid]

    def publish(self, topic: str, payload: bytes, retain: bool = False):
        return self._wait_ack(self.client.publish(topic, payload, qos=1, retain=retain).mid)

    def subscribe(self, topic: str):
        return self._wait_ack(self.client.subscribe(topic, qos=1)[1])

    def drop_connection(self) -> None:
        """Close the socket without DISCONNECT so the broker publishes the Last Will."""
        self.client.loop_stop()
        self.client.socket().close()
