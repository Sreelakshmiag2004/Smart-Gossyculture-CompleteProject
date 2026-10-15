"""MQTT acknowledgement semantics: PUBACK only after the handler returned (durable outcome)."""

import json
from types import SimpleNamespace

import aiomqtt
import pytest
from paho.mqtt.enums import MQTTErrorCode

from gossy.ingest import consumer as consumer_module
from gossy.ingest.consumer import MqttConsumer, acknowledge, enable_manual_ack, msg_id_hint


async def test_manual_ack_hook_matches_the_pinned_libraries():  # aiomqtt needs a running loop
    # aiomqtt 2.5.1 wraps paho 2.1.0 as `_client`; paho's own API switches PUBACK to manual.
    # If a library upgrade changes this, this test fails instead of silently re-opening the
    # acknowledge-before-commit window.
    client = aiomqtt.Client("localhost", identifier="unit-test")
    assert client._client._manual_ack is False  # noqa: SLF001 - library default (auto PUBACK)
    enable_manual_ack(client)
    assert client._client._manual_ack is True  # noqa: SLF001


class FakePaho:
    def __init__(self, events, rc=MQTTErrorCode.MQTT_ERR_SUCCESS):
        self.events = events
        self.rc = rc

    def ack(self, mid, qos):
        self.events.append(("puback", mid))
        return self.rc


def message(mid, payload=b"{}", qos=1):
    return SimpleNamespace(topic="bollbot/v1/sim-0001/telemetry", payload=payload, mid=mid, qos=qos)


def consumer(handler):
    c = MqttConsumer.__new__(MqttConsumer)  # no settings/TLS needed for process()
    c._handler = handler
    c._faults = consumer_module.NO_FAULTS
    c.acked = c.ack_failures = 0
    return c


async def test_puback_is_sent_only_after_the_handler_returns():
    events = []

    async def handler(topic, payload):
        events.append(("handled", topic))
        return "ingested"

    c = consumer(handler)
    client = SimpleNamespace(_client=FakePaho(events))
    for mid in (1, 2, 3):
        await c.process(client, message(mid))
    handled = ("handled", "bollbot/v1/sim-0001/telemetry")
    assert events == [handled, ("puback", 1), handled, ("puback", 2), handled, ("puback", 3)]
    assert c.acked == 3


async def test_no_puback_when_the_handler_fails():
    events = []

    async def handler(topic, payload):
        raise RuntimeError("could not make the outcome durable")

    c = consumer(handler)
    with pytest.raises(RuntimeError):
        await c.process(SimpleNamespace(_client=FakePaho(events)), message(7))
    assert events == [] and c.acked == 0


async def test_failed_puback_is_counted_not_raised():
    async def handler(topic, payload):
        return "duplicate"

    c = consumer(handler)
    await c.process(SimpleNamespace(_client=FakePaho([], rc=MQTTErrorCode.MQTT_ERR_NO_CONN)), message(9))
    assert c.ack_failures == 1 and c.acked == 0


def test_qos0_needs_no_puback():
    assert acknowledge(SimpleNamespace(_client=None), message(1, qos=0)) is True


def test_msg_id_hint_is_best_effort():
    assert msg_id_hint(json.dumps({"msgId": "01ABC"}).encode()) == "01ABC"
    assert msg_id_hint(b"not json") is None and msg_id_hint(b"[1]") is None
