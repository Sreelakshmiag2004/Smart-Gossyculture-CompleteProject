"""Long-running MQTT subscriber: manual acknowledgement, reconnect + exponential backoff.

Acknowledgement semantics (Phase 2.5):
* QoS 1 subscriptions, persistent session (clean_start=False, session expiry) with a fixed
  client id: the broker keeps every message it has not received a PUBACK for, across ingest
  restarts and reconnects, and redelivers it (DUP flag) on the next connection.
* Manual acknowledgement: paho's automatic PUBACK (sent as soon as a message is handed to the
  library) is switched off. PUBACK is sent only after ``handler`` has returned, i.e. after the
  outcome is committed in the database. Messages are handled strictly one at a time, so
  PUBACKs are sent in arrival order (MQTT 5 section 4.6).
* A crash at ANY point before the PUBACK leaves the message with the broker; it is redelivered
  and the msgId idempotency ledger turns a redelivery of an already-committed message into a
  harmless duplicate. Effects are exactly-once; delivery is at-least-once.
* If the handler raises, the message is not acknowledged and the connection is dropped, so the
  broker redelivers it after reconnect.

This client never publishes: it has no publish code path, and the broker ACL grants the ingest
credential read access only (no backend-to-device commands in v1).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any

import aiomqtt
from paho.mqtt.enums import MQTTErrorCode
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

from gossy.config import MqttSettings
from gossy.contracts.topics import INGEST_SUBSCRIPTIONS
from gossy.ingest.faults import AFTER_COMMIT, NO_FAULTS, FaultInjector
from gossy.mqtt.connection import build_tls_context

log = logging.getLogger("gossy.ingest.mqtt")

MessageHandler = Callable[[str, bytes], Awaitable[Any]]


def enable_manual_ack(client: aiomqtt.Client) -> None:
    """aiomqtt 2.5 has no manual-ack option; switch it on in the wrapped paho client (public
    paho API). tests/unit/test_consumer.py pins this against the locked library versions."""
    client._client.manual_ack_set(True)  # noqa: SLF001


def acknowledge(client: aiomqtt.Client, message: aiomqtt.Message) -> bool:
    if message.qos == 0:
        return True
    rc = client._client.ack(message.mid, message.qos)  # noqa: SLF001
    return rc == MQTTErrorCode.MQTT_ERR_SUCCESS


def msg_id_hint(payload: bytes) -> str | None:
    """Best-effort msgId for failure-injection matching only (no validation implied)."""
    try:
        value = json.loads(payload).get("msgId")
    except (ValueError, AttributeError):
        return None
    return value if isinstance(value, str) and len(value) <= 64 else None


class MqttConsumer:
    def __init__(self, settings: MqttSettings, handler: MessageHandler, faults: FaultInjector = NO_FAULTS):
        self._settings = settings
        self._handler = handler
        self._faults = faults
        self._password = settings.password_value()
        self._tls = build_tls_context(settings.ca_file)
        self.connected = False
        self.connect_count = 0
        self.acked = 0
        self.ack_failures = 0
        self.errors = 0

    def _client(self) -> aiomqtt.Client:
        properties = Properties(PacketTypes.CONNECT)
        properties.SessionExpiryInterval = self._settings.session_expiry_s
        client = aiomqtt.Client(
            hostname=self._settings.host,
            port=self._settings.port,
            username=self._settings.username,
            password=self._password,
            identifier=self._settings.client_id,
            protocol=aiomqtt.ProtocolVersion.V5,
            clean_start=False,
            properties=properties,
            keepalive=self._settings.keepalive_s,
            tls_context=self._tls,
            timeout=10,
        )
        enable_manual_ack(client)
        return client

    async def process(self, client: aiomqtt.Client, message: aiomqtt.Message) -> None:
        """Handle one message, then acknowledge it. Raises (without acknowledging) on failure."""
        payload = message.payload if isinstance(message.payload, bytes | bytearray) else str(message.payload or "").encode()
        outcome = await self._handler(str(message.topic), bytes(payload))
        if self._faults.enabled and str(outcome) == "ingested":
            hint = msg_id_hint(bytes(payload))
            if hint:
                self._faults.check(AFTER_COMMIT, hint)
        if acknowledge(client, message):
            self.acked += 1
        else:
            # The connection that delivered the message is gone. The broker still holds the
            # message and will redeliver it; the ledger makes that redelivery a duplicate.
            self.ack_failures += 1
            log.warning("mqtt_ack_failed_will_be_redelivered", extra={"mid": message.mid, "topic": str(message.topic)})

    async def run(self) -> None:
        delay = self._settings.reconnect_min_s
        while True:
            try:
                async with self._client() as client:
                    for subscription in INGEST_SUBSCRIPTIONS:
                        await client.subscribe(subscription, qos=1)
                    self.connected = True
                    self.connect_count += 1
                    delay = self._settings.reconnect_min_s
                    log.info("mqtt_connected", extra={"host": self._settings.host, "client_id": self._settings.client_id, "subscriptions": list(INGEST_SUBSCRIPTIONS), "manual_ack": True})
                    async for message in client.messages:
                        await self.process(client, message)
                # Iterator ended without an error: treat as a disconnect and reconnect.
                raise aiomqtt.MqttError("message stream ended")
            except aiomqtt.MqttError as exc:
                self.connected = False
                log.warning("mqtt_disconnected", extra={"error": str(exc), "retry_in_s": delay})
                await asyncio.sleep(delay)
                delay = min(delay * 2, self._settings.reconnect_max_s)
            except asyncio.CancelledError:
                self.connected = False
                log.info("mqtt_consumer_stopped")
                raise
            except Exception:
                # Handler could not make the outcome durable (or an unexpected bug): the message
                # was NOT acknowledged. Drop the connection so the broker redelivers it.
                self.connected = False
                self.errors += 1
                log.exception("mqtt_consumer_error_message_not_acknowledged", extra={"retry_in_s": delay})
                await asyncio.sleep(delay)
                delay = min(delay * 2, self._settings.reconnect_max_s)
