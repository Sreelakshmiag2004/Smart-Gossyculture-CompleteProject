"""Event document shape, NOTIFY size handling, per-subscriber filtering and overflow."""

import json
from datetime import UTC, datetime

from gossy.realtime import hub as hub_module
from gossy.realtime.events import NOTIFY_MAX_BYTES, event_message, notify_payload
from gossy.realtime.hub import EventHub

TS = datetime(2026, 9, 29, 12, 0, tzinfo=UTC)


def ev(cursor, device="sim-0002", data=None):
    return event_message(cursor=cursor, kind="telemetry", device_id=device, msg_id=f"MSG{cursor}", ts=TS, received_at=TS, data=data or {"batteryPct": 80}, alerts_json=[])


def test_event_shape():
    e = ev(7)
    assert set(e) == {"type", "cursor", "kind", "deviceId", "msgId", "ts", "receivedAt", "data", "alerts"}
    assert e["type"] == "event" and e["cursor"] == 7


def test_notify_payload_small_events_inline_large_events_by_reference():
    small = json.loads(notify_payload(ev(1)))
    assert small["data"] == {"batteryPct": 80}
    big = json.loads(notify_payload(ev(2, data={"blob": "x" * (NOTIFY_MAX_BYTES + 10)})))
    assert big == {"type": "event", "cursor": 2, "deviceId": "sim-0002", "truncated": True}


async def test_hub_delivers_only_allowed_devices():
    hub = EventHub(engine=None)
    mine, other = hub.subscribe(), hub.subscribe()
    mine.allowed, other.allowed = {"sim-0002"}, {"bb-999999"}
    await hub.dispatch(ev(1))
    assert mine.queue.qsize() == 1 and other.queue.qsize() == 0
    assert hub.last_cursor == 1


async def test_slow_subscriber_is_flagged_not_blocking():
    hub = EventHub(engine=None, max_queue=10)
    slow = hub.subscribe()
    slow.allowed = {"sim-0002"}
    for i in range(1, 15):
        await hub.dispatch(ev(i))
    assert slow.queue.qsize() == 10 and slow.overflowed.is_set()


async def test_catch_up_delivers_missed_events(monkeypatch):
    missed = [ev(5), ev(6)]

    async def fake_load(engine, device_ids, *, after, limit):
        assert device_ids is None and after == 4
        return missed

    monkeypatch.setattr(hub_module, "load_events", fake_load)
    hub = EventHub(engine=None)
    hub.last_cursor = 4
    sub = hub.subscribe()
    sub.allowed = {"sim-0002"}
    await hub.catch_up()
    assert [sub.queue.get_nowait()["cursor"] for _ in range(2)] == [5, 6]


async def test_listener_catches_up_on_first_connect_and_on_reconnect(monkeypatch):
    # The hub's starting cursor is read before LISTEN, so even the first connect must catch up.
    import asyncio

    from gossy.realtime import listener as listener_module
    from gossy.realtime.listener import PgEventListener

    connects = []

    class FakeConn:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def execute(self, sql):
            assert sql == "LISTEN gossy_events"

        async def notifies(self):
            if len(connects) == 1:
                yield type("N", (), {"payload": json.dumps(ev(1))})()
                raise ConnectionError("server closed the connection")
            await asyncio.Event().wait()  # second connection stays open
            yield  # pragma: no cover

    async def fake_connect(dsn, autocommit):
        connects.append(dsn)
        return FakeConn()

    monkeypatch.setattr(listener_module.psycopg.AsyncConnection, "connect", fake_connect)
    events, catch_ups = [], []

    async def on_event(e):
        events.append(e["cursor"])

    async def on_connect():
        catch_ups.append(len(connects))

    listener = PgEventListener("dsn", on_event, on_connect)
    task = asyncio.create_task(listener.run())
    for _ in range(100):  # the listener backs off 1 s before reconnecting
        if len(catch_ups) == 2:
            break
        await asyncio.sleep(0.05)
    task.cancel()
    assert catch_ups == [1, 2] and events == [1] and listener.connect_count == 2


async def test_catch_up_overflow_forces_clients_to_resume(monkeypatch):
    async def fake_load(engine, device_ids, *, after, limit):
        return [ev(i) for i in range(limit)]

    monkeypatch.setattr(hub_module, "load_events", fake_load)
    hub = EventHub(engine=None)
    sub = hub.subscribe()
    await hub.catch_up()
    assert sub.overflowed.is_set()
