"""Contract conformance: everything the simulator emits must pass the ingest boundary validator."""

import json
import random
from datetime import timedelta

import pytest

from gossy.contracts.topics import MessageKind
from gossy.ingest.validation import parse_message
from gossy_sim.device import SimulatedDevice
from tests.conftest import NOW

LIMITS = {"now": NOW, "max_payload_bytes": 65536, "max_future_skew": timedelta(minutes=5)}


@pytest.fixture
def device():
    return SimulatedDevice("sim-0001", rng=random.Random(7), clock=lambda: NOW)


def test_every_generated_message_is_contract_valid(device):
    messages = [device.status("online"), device.telemetry(), device.harvest(), device.last_will()]
    pest = device.pest()
    messages += [pest, device.spray(related_msg_id=pest.msg_id)]
    for i in range(50):
        messages += [device.telemetry(), device.pest(), device.harvest(),
                     device.scan(row=i + 1, segment=2), device.pick(row=i + 1, segment=2)]
    for m in messages:
        parsed = parse_message(m.topic, m.payload, **LIMITS)
        assert parsed.envelope.msg_id == m.msg_id
        assert parsed.kind is m.kind


def test_sequence_numbers_increase(device):
    seqs = [json.loads(device.telemetry().payload)["seq"] for _ in range(5)]
    assert seqs == [0, 1, 2, 3, 4]


def test_spray_links_to_pest(device):
    pest = device.pest()
    spray = json.loads(device.spray(related_msg_id=pest.msg_id).payload)
    assert spray["data"]["relatedMsgId"] == pest.msg_id
    assert 1000 <= spray["data"]["durationMs"] <= 2000


def test_status_messages_are_retained_others_not(device):
    assert device.status("online").retain and device.last_will().retain
    assert not device.telemetry().retain


def test_only_simulator_device_ids_allowed():
    for bad in ("bb-000123", "svc-ingest", "sim"):
        with pytest.raises(ValueError):
            SimulatedDevice(bad)


def test_harvest_picked_follows_maturity_only(device):
    # No moisture threshold is applied (U-1 unresolved).
    for _ in range(100):
        data = json.loads(device.harvest().payload)["data"]
        assert data["picked"] == (data["maturity"] == "mature")


def test_simulator_emits_no_command_topics(device):
    kinds = {device.telemetry().kind, device.pest().kind, device.spray().kind, device.harvest().kind,
             device.scan().kind, device.pick().kind, device.status("online").kind}
    assert kinds == set(MessageKind)


# ----------------------------------------------------------------------------- Phase 5A: modes
class _FakeClient:
    """Stands in for the broker connection: records what is published, in order."""

    def __init__(self):
        self.published: list[tuple[str, dict]] = []
        self.open = False

    async def __aenter__(self):
        self.open = True
        return self

    async def __aexit__(self, *exc):
        self.open = False

    async def publish(self, topic, payload, qos, retain):
        assert self.open, "published on a closed connection"
        self.published.append((topic.split("/", 3)[3], json.loads(payload)))


async def _run(monkeypatch, device, **kwargs):
    from gossy_sim import publisher

    client, sleeps = _FakeClient(), []

    async def no_sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr(publisher, "connect", lambda device, broker, **_: client)
    monkeypatch.setattr(publisher.asyncio, "sleep", no_sleep)
    options = {"interval_s": 60.0, "count": 5, "pest_probability": 0.0, "harvest_probability": 0.0, "duplicate_every": 0, "rng": random.Random(1)}
    sent = await publisher.run_simulation(device, broker=None, **{**options, **kwargs})
    return client, sleeps, sent


def test_default_interval_is_the_contract_reporting_interval():
    from gossy_sim.__main__ import DEFAULT_INTERVAL_S, parse_args

    base = ["--device-id", "sim-0001", "--ca-file", "ca.crt", "--password-file", "p"]
    args = parse_args(base)
    assert DEFAULT_INTERVAL_S == 60.0 and args.interval == 60.0
    assert args.silent_after == 0, "a normal device never goes silent"
    assert parse_args([*base, "--interval", "5", "--silent-after", "3"]).silent_after == 3


async def test_normal_mode_reports_every_interval_and_goes_offline_at_the_end(monkeypatch, device):
    client, sleeps, sent = await _run(monkeypatch, device)
    kinds = [kind for kind, _ in client.published]
    assert kinds == ["status", *["telemetry"] * 5, "status"]
    assert client.published[0][1]["data"] == {"state": "online"} and client.published[-1][1]["data"] == {"state": "offline"}
    assert sleeps == [60.0] * 4, "one interval between reports"
    assert sent == len(client.published) - 1  # the first "online" is not counted


async def test_online_but_silent_mode_stops_reporting_and_stays_connected(monkeypatch, device):
    client, sleeps, _ = await _run(monkeypatch, device, count=8, silent_after=2, pest_probability=1.0, harvest_probability=1.0)
    kinds = [kind for kind, _ in client.published]
    # two reporting ticks (telemetry + the events of those ticks), then nothing until the run ends
    assert kinds.count("telemetry") == 2
    last_report = max(i for i, k in enumerate(kinds) if k == "telemetry")
    assert set(kinds[last_report + 1:-1]) <= {"event/pest", "event/spray", "event/harvest"}
    assert kinds[-1] == "status" and client.published[-1][1]["data"] == {"state": "offline"}
    statuses = [body["data"]["state"] for kind, body in client.published if kind == "status"]
    assert statuses == ["online", "offline"], "no status is published while silent: the device stays online"
    # the connection is held for the remaining six ticks (keep-alive is the client library's job)
    assert sleeps == [60.0] * 7


async def test_silent_forever_publishes_nothing_after_the_last_report(monkeypatch, device):
    from gossy_sim import publisher

    client, ticks = _FakeClient(), 0

    class Stop(Exception):
        pass

    async def counted_sleep(seconds):
        nonlocal ticks
        ticks += 1
        if ticks > 50:
            raise Stop

    monkeypatch.setattr(publisher, "connect", lambda device, broker, **_: client)
    monkeypatch.setattr(publisher.asyncio, "sleep", counted_sleep)
    with pytest.raises(Stop):  # count=0 runs until the process is stopped
        await publisher.run_simulation(device, broker=None, interval_s=60.0, count=0, pest_probability=0.0, harvest_probability=0.0, duplicate_every=0, rng=random.Random(1), silent_after=1)
    assert [kind for kind, _ in client.published] == ["status", "telemetry"]
    assert client.published[0][1]["data"] == {"state": "online"}, "and no offline status: a killed device is the broker's Last Will"
