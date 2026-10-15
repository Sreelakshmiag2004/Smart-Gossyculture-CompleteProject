"""Live-monitoring WebSocket (gossy.ws.v1): authentication, authorization, event delivery,
reconnect/resume, and proof that the channel cannot send anything to devices."""

import asyncio
import json
import time

import pytest
from websockets.exceptions import ConnectionClosed, InvalidStatus

from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import FARMER_A, FARMER_B, TEST_DEVICE, PahoSession, bearer, login, own_device, publish_as_test_device, wait_ingested, ws_connect, ws_recv, ws_recv_until

pytestmark = pytest.mark.integration


def is_type(t):
    return lambda m: m["type"] == t


def event_for(msg_id):
    return lambda m: m["type"] == "event" and m["msgId"] == msg_id


async def started(ws, op=None):
    hello = await ws_recv(ws)
    assert hello["type"] == "hello"
    await ws.send(json.dumps(op or {"op": "start"}))
    return hello


# --------------------------------------------------------------------------- authentication

async def test_connection_without_token_is_rejected():
    with pytest.raises(InvalidStatus) as exc:
        async with ws_connect():
            pass
    assert exc.value.response.status_code == 403


async def test_connection_with_invalid_token_is_rejected():
    with pytest.raises(InvalidStatus) as exc:
        async with ws_connect(token="not-a-valid-jwt"):
            pass
    assert exc.value.response.status_code == 403


async def test_connection_with_revoked_session_is_rejected(api):
    tokens = await login(api, FARMER_A)
    await api.post("/api/v1/auth/logout", headers=bearer(tokens))
    with pytest.raises(InvalidStatus) as exc:
        async with ws_connect(tokens):
            pass
    assert exc.value.response.status_code == 403


async def test_authenticated_connection_receives_hello(api):
    tokens = await login(api, FARMER_A)
    async with ws_connect(tokens) as ws:
        hello = await ws_recv(ws)
    assert hello["type"] == "hello" and hello["protocol"] == "gossy.ws.v1"
    assert hello["allowedOps"] == ["start", "resume", "ping"]
    assert isinstance(hello["latestCursor"], int) and hello["tokenExpiresAt"] and hello["heartbeatIntervalS"] > 0


# --------------------------------------------------------------------------- delivery + authorization

async def test_live_event_delivered_only_to_authorized_clients(api, engine):
    a, b = await login(api, FARMER_A), await login(api, FARMER_B)
    await own_device(api, a)
    pest = SimulatedDevice(TEST_DEVICE).pest()
    async with ws_connect(a) as ws_a, ws_connect(b) as ws_b:
        await started(ws_a)
        await started(ws_b)
        await ws_recv_until(ws_a, is_type("resumed"))
        await ws_recv_until(ws_b, is_type("resumed"))
        t0 = time.monotonic()
        await publish_as_test_device([pest])
        event, _ = await ws_recv_until(ws_a, event_for(pest.msg_id))
        latency = time.monotonic() - t0
        # B: nothing but heartbeats before the pong it asked for.
        await ws_b.send(json.dumps({"op": "ping"}))
        _, before_pong = await ws_recv_until(ws_b, is_type("pong"))
    assert all(m["type"] == "heartbeat" for m in before_pong), before_pong
    assert event["deviceId"] == TEST_DEVICE and event["kind"] == "event/pest" and event["cursor"] > 0
    assert event["data"] == json.loads(pest.payload)["data"]
    assert [x["type"] for x in event["alerts"]] == ["pest_detected"]
    assert latency < 5, f"publish -> WebSocket took {latency:.2f}s"


async def test_heartbeat_and_ping(api):
    tokens = await login(api, FARMER_A)
    async with ws_connect(tokens) as ws:
        hello = await started(ws)
        await ws.send(json.dumps({"op": "ping"}))
        await ws_recv_until(ws, is_type("pong"))
        beat, _ = await ws_recv_until(ws, is_type("heartbeat"), timeout=hello["heartbeatIntervalS"] + 5)
    assert "serverTime" in beat and isinstance(beat["cursor"], int)


# --------------------------------------------------------------------------- reconnect / resume

async def test_resume_replays_missed_events_once_in_order_then_continues_live(api, engine):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    device = SimulatedDevice(TEST_DEVICE)
    async with ws_connect(a) as ws:
        await started(ws)
        resumed, _ = await ws_recv_until(ws, is_type("resumed"))
    last_cursor = resumed["cursor"]

    missed = [device.telemetry(), device.telemetry(), device.pest()]
    await publish_as_test_device(missed)  # published while the client is disconnected
    await wait_ingested(engine, [m.msg_id for m in missed])

    live = device.telemetry()
    async with ws_connect(a) as ws:
        await started(ws, {"op": "resume", "cursor": last_cursor})
        done, before = await ws_recv_until(ws, is_type("resumed"))
        replayed = [m for m in before if m["type"] == "event"]
        await publish_as_test_device([live])
        live_event, between = await ws_recv_until(ws, event_for(live.msg_id))
    replayed_ids = [m["msgId"] for m in replayed]
    assert [m.msg_id for m in missed] == [i for i in replayed_ids if i in {m.msg_id for m in missed}]
    cursors = [m["cursor"] for m in replayed] + [live_event["cursor"]]
    assert cursors == sorted(set(cursors)) and cursors[0] > last_cursor  # strictly increasing, no duplicates
    assert done["replayed"] == len(replayed) and done["cursor"] == replayed[-1]["cursor"]
    assert all(m["msgId"] not in replayed_ids for m in between if m["type"] == "event")


async def test_resume_argument_validation(api):
    tokens = await login(api, FARMER_A)
    async with ws_connect(tokens) as ws:
        await ws_recv(ws)
        for bad in (-1, "12", 1.5, None, True):
            await ws.send(json.dumps({"op": "resume", "cursor": bad}))
            err, _ = await ws_recv_until(ws, is_type("error"))
            assert err["code"] == "invalid_cursor", bad
        await ws.send(json.dumps({"op": "start"}))
        await ws_recv_until(ws, is_type("resumed"))
        await ws.send(json.dumps({"op": "resume", "cursor": 0}))
        err, _ = await ws_recv_until(ws, is_type("error"))
        assert err["code"] == "already_started"
        await ws.send("not json")
        err, _ = await ws_recv_until(ws, is_type("error"))
        assert err["code"] == "invalid_message"


async def test_session_revoked_while_connected_closes_the_socket(api):
    tokens = await login(api, FARMER_A)
    async with ws_connect(tokens) as ws:
        await started(ws)
        await ws_recv_until(ws, is_type("resumed"))
        await api.post("/api/v1/auth/logout", headers=bearer(tokens))
        err, _ = await ws_recv_until(ws, is_type("error"), timeout=15)
        assert err["code"] == "session_revoked"
        with pytest.raises(ConnectionClosed) as exc:
            await ws_recv(ws)
    assert exc.value.rcvd.code == 4401


async def test_oversized_client_frame_closes_the_socket(api):
    tokens = await login(api, FARMER_A)
    async with ws_connect(tokens) as ws:
        await ws_recv(ws)
        await ws.send(json.dumps({"op": "ping", "pad": "x" * 5000}))
        with pytest.raises(ConnectionClosed) as exc:
            while True:
                await ws_recv(ws)
    assert exc.value.rcvd.code == 1009


# --------------------------------------------------------------------------- v1 boundary: no device commands

COMMANDS = [
    {"op": "command", "deviceId": TEST_DEVICE, "action": "spray"},
    {"op": "publish", "topic": f"bollbot/v1/{TEST_DEVICE}/command", "payload": {"cmd": "start"}},
    {"op": "harvest", "deviceId": TEST_DEVICE},
    {"op": "spray", "deviceId": TEST_DEVICE, "durationMs": 1000},
    {"op": "stop", "deviceId": TEST_DEVICE},
]


async def test_websocket_has_no_device_command_channel(api):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    # Read-authorised observer on every device topic: proves nothing reaches the broker.
    with PahoSession("svc-ingest", "itest-ws-no-command") as observer:
        observer.subscribe("bollbot/v1/#")
        await asyncio.sleep(1)
        observer.received.clear()  # drop retained status messages
        async with ws_connect(a) as ws:
            await started(ws)
            await ws_recv_until(ws, is_type("resumed"))
            for command in COMMANDS:
                await ws.send(json.dumps(command))
                err, _ = await ws_recv_until(ws, is_type("error"))
                assert err["code"] == "unsupported_op" and "cannot send commands" in err["message"]
            await ws.send(json.dumps({"op": "ping"}))
            await ws_recv_until(ws, is_type("pong"))  # connection still healthy, read-only
        await asyncio.sleep(2)
        assert observer.received == []
