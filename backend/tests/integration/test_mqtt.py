"""Broker connectivity, TLS, authentication and ACL (including: backend cannot publish commands)."""

import socket
import ssl
import time

import aiomqtt
import pytest

from gossy.contracts.topics import MessageKind, topic_for
from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import MQTT_HOST, MQTT_PORT, TEST_DEVICE, PahoSession, password, tls

pytestmark = pytest.mark.integration

NOT_AUTHORIZED = 135


def client(username, pwd, *, tls_context=None, identifier="itest-conn"):
    return aiomqtt.Client(
        MQTT_HOST, MQTT_PORT, username=username, password=pwd, identifier=identifier,
        protocol=aiomqtt.ProtocolVersion.V5, tls_context=tls_context or tls(), timeout=10,
    )


async def test_device_connects_over_tls():
    async with client(TEST_DEVICE, password(TEST_DEVICE)):
        pass


async def test_anonymous_connection_refused():
    with pytest.raises(aiomqtt.MqttError):
        async with client(None, None):
            pass


async def test_wrong_password_refused():
    with pytest.raises(aiomqtt.MqttError):
        async with client(TEST_DEVICE, "devonly-wrong-password"):
            pass


async def test_untrusted_server_certificate_refused():
    # Default system trust store does not contain the development CA -> verification fails.
    with pytest.raises((aiomqtt.MqttError, ssl.SSLError, OSError)):
        async with client(TEST_DEVICE, password(TEST_DEVICE), tls_context=ssl.create_default_context()):
            pass


def test_plaintext_port_1883_is_not_available():
    with pytest.raises(OSError):
        socket.create_connection((MQTT_HOST, 1883), timeout=3).close()


def test_device_can_publish_to_its_own_topic():
    msg = SimulatedDevice(TEST_DEVICE).telemetry()
    with PahoSession(TEST_DEVICE, "itest-own-topic") as s:
        assert not s.publish(msg.topic, msg.payload).is_failure


def test_device_cannot_publish_as_another_device():
    other = SimulatedDevice("sim-0001").telemetry()
    with PahoSession(TEST_DEVICE, "itest-spoof") as s:
        assert s.publish(other.topic, other.payload).value == NOT_AUTHORIZED


def test_device_receives_nothing_from_the_broker():
    # Mosquitto's ACL file grants the SUBACK for wildcard filters and enforces read permission
    # per message at delivery. The security property is therefore: a device never RECEIVES
    # anything (no telemetry of other devices, no cloud-to-device traffic).
    other = SimulatedDevice("sim-0001").telemetry()
    with (
        PahoSession(TEST_DEVICE, "itest-dev-sub") as subscriber,
        PahoSession("svc-ingest", "itest-control-sub") as control,  # read-authorised control
        PahoSession("sim-0001", "itest-dev-pub") as publisher,
    ):
        subscriber.subscribe("bollbot/v1/#")
        subscriber.subscribe(other.topic)
        control.subscribe(other.topic)
        assert not publisher.publish(other.topic, other.payload).is_failure
        time.sleep(2)
        assert len(control.received) == 1, "control subscriber should receive the message"
        assert subscriber.received == []


@pytest.mark.parametrize(
    "topic",
    [
        topic_for("sim-0001", MessageKind.TELEMETRY),
        "bollbot/v1/sim-0001/command",
        "bollbot/v1/sim-0001/config",
        "bollbot/v1/sim-0001/control/spray",
    ],
)
def test_backend_ingest_account_cannot_publish_to_devices(topic):
    # v1 boundary: the backend has no way to send operational commands to devices.
    with PahoSession("svc-ingest", "itest-svc-no-publish") as s:
        assert s.publish(topic, b'{"cmd":"start"}').value == NOT_AUTHORIZED
