"""Upload the outbox to the backend when the network is available (spec Section 11).

Records go up strictly in order. On any failure the service stops the batch,
waits (5 s, 10 s, 20 s ... up to 5 min) and tries again from the same record.
Success resets the wait. The uploader is pluggable so it can be tested
without Firebase.
"""
from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Callable, Protocol

from .store import Outbox

log = logging.getLogger(__name__)


class PermanentUploadError(Exception):
    """The record can never be uploaded as it is; retrying will not help."""


class Uploader(Protocol):
    def upload(self, kind: str, doc_id: str, payload: dict, msg_id: str = "", seq: int = 0) -> None:
        """Upload one record; raise on failure (PermanentUploadError: never retry)."""


class SyncService:
    def __init__(self, outbox: Outbox, uploader: Uploader, min_backoff_s: float = 5,
                 max_backoff_s: float = 300, batch: int = 20,
                 clock: Callable[[], float] = time.monotonic):
        self.outbox, self.uploader = outbox, uploader
        self.min_backoff, self.max_backoff, self.batch = min_backoff_s, max_backoff_s, batch
        self.clock = clock
        self._backoff = min_backoff_s
        self._next_try = 0.0
        self.last_success: float | None = None

    def step(self) -> int:
        """Try one batch. Returns the number of records uploaded."""
        now = self.clock()
        if now < self._next_try:
            return 0
        sent = 0
        for item in self.outbox.pending(self.batch):
            try:
                self.uploader.upload(item.kind, item.doc_id, item.payload,
                                     msg_id=item.msg_id, seq=item.seq)
            except PermanentUploadError as e:
                self.outbox.mark_dead(item.id, str(e))       # do not block the queue
                log.error("dropped %s/%s: %s", item.kind, item.doc_id, e)
                continue
            except Exception as e:  # noqa: BLE001 - any failure means 'retry later'
                self.outbox.mark_failed(item.id, f"{type(e).__name__}: {e}")
                self._next_try = now + self._backoff
                log.warning("upload failed (%s); retry in %.0f s", e, self._backoff)
                self._backoff = min(self._backoff * 2, self.max_backoff)
                return sent
            self.outbox.mark_sent(item.id)
            sent += 1
        if sent:
            self._backoff = self.min_backoff
            self.last_success = now
        return sent

    def run(self, stop: Callable[[], bool], idle_s: float = 2.0) -> None:
        """Loop until stop() is true (run in a background thread)."""
        while not stop():
            if self.step() == 0:
                time.sleep(idle_s)


class MqttCloudUploader:
    """Publishes outbox records to the backend broker as contract `bollbot/v1` messages
    (backend/docs/mqtt-contract.md): MQTT 5 over TLS, QoS 1, username = deviceId.

    A record counts as uploaded only after the broker's PUBACK, and it is always re-sent
    with the SAME msgId, so the backend stores it exactly once. Online/offline status is
    published on connect and as the Last Will, never through the outbox (contract rule).
    Requires: pip install paho-mqtt (>= 2.0).
    """

    def __init__(self, device_id: str, host: str, port: int, ca_file: str, password: str,
                 seq_fn: Callable[[], int], timeout_s: float = 10.0, client=None):
        from datetime import datetime
        from bollbot.core.rules import IST
        from . import contract
        self.device_id = contract.check_device_id(device_id)
        self.timeout_s, self._contract, self._seq = timeout_s, contract, seq_fn
        self._now = lambda: datetime.now(IST).isoformat(timespec="milliseconds")
        if client is None:
            import paho.mqtt.client as mqtt
            client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=device_id,
                                 protocol=mqtt.MQTTv5)
            client.username_pw_set(device_id, password)
            client.tls_set(ca_certs=ca_file)
            client.reconnect_delay_set(1, 60)
        self._c = client
        self.connected = False
        self._refused: dict[int, str] = {}       # mid -> PUBACK reason code, if not success
        topic, will = contract.status_envelope(device_id, "offline", self._now(), seq_fn())
        self._c.will_set(topic, json.dumps(will), qos=1, retain=True)
        self._c.on_connect = self._on_connect
        self._c.on_disconnect = self._on_disconnect
        self._c.on_publish = self._on_publish
        self._c.connect_async(host, port, keepalive=30)
        self._c.loop_start()

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        ok = getattr(reason_code, "is_failure", None)
        self.connected = (not ok) if ok is not None else reason_code == 0
        if self.connected:
            topic, msg = self._contract.status_envelope(self.device_id, "online", self._now(), self._seq())
            client.publish(topic, json.dumps(msg), qos=1, retain=True)
        else:
            log.warning("broker refused connection: %s", reason_code)

    def _on_disconnect(self, client, userdata, *args):
        self.connected = False

    def _on_publish(self, client, userdata, mid, reason_code=None, properties=None):
        # MQTT 5: the broker answers a denied publish with a PUBACK carrying a failure
        # code (e.g. 0x87 Not authorized). paho still marks it "published", so record it.
        if reason_code is not None and getattr(reason_code, "is_failure", False):
            self._refused[mid] = str(reason_code)

    def upload(self, kind: str, doc_id: str, payload: dict, msg_id: str = "", seq: int = 0) -> None:
        try:
            topic, env = self._contract.envelope(kind, payload, self.device_id, msg_id, seq)
        except (self._contract.NotForCloud, KeyError, TypeError, ValueError) as e:
            raise PermanentUploadError(str(e)) from e
        if not msg_id:
            raise PermanentUploadError("record has no msgId")
        if not self.connected:
            raise ConnectionError("not connected to the broker")
        info = self._c.publish(topic, json.dumps(env, ensure_ascii=False), qos=1)
        info.wait_for_publish(timeout=self.timeout_s)
        if not info.is_published():
            raise TimeoutError("no PUBACK from the broker")
        refused = self._refused.pop(info.mid, None)
        if refused:
            # Kept in the outbox (not dead-lettered): this is a broker ACL/config problem
            # that an operator can fix, and the data must not be lost meanwhile.
            raise ConnectionError(f"broker refused {topic}: {refused} - check the broker ACL")

    def close(self) -> None:
        try:
            topic, msg = self._contract.status_envelope(self.device_id, "offline", self._now(), self._seq())
            self._c.publish(topic, json.dumps(msg), qos=1, retain=True).wait_for_publish(timeout=3)
        except Exception:  # noqa: BLE001 - the broker publishes the Last Will anyway
            pass
        self._c.disconnect()
        self._c.loop_stop()
