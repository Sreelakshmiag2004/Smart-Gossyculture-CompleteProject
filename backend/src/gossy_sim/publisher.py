"""MQTT publishing for the simulator (QoS 1, TLS, Last Will)."""

from __future__ import annotations

import asyncio
import logging
import random
import ssl
from collections.abc import Iterable
from dataclasses import dataclass

import aiomqtt

from gossy_sim.device import OutgoingMessage, SimulatedDevice

log = logging.getLogger("gossy.sim")


@dataclass(frozen=True)
class BrokerConfig:
    host: str
    port: int
    username: str
    password: str
    tls_context: ssl.SSLContext


def connect(device: SimulatedDevice, broker: BrokerConfig, *, will: bool = True) -> aiomqtt.Client:
    will_msg = None
    if will:
        lw = device.last_will()
        will_msg = aiomqtt.Will(topic=lw.topic, payload=lw.payload, qos=1, retain=True)
    return aiomqtt.Client(
        hostname=broker.host,
        port=broker.port,
        username=broker.username,
        password=broker.password,
        identifier=f"{device.device_id}-sim",
        protocol=aiomqtt.ProtocolVersion.V5,
        tls_context=broker.tls_context,
        will=will_msg,
        keepalive=30,
        timeout=10,
    )


async def publish_all(client: aiomqtt.Client, messages: Iterable[OutgoingMessage]) -> list[OutgoingMessage]:
    sent = []
    for m in messages:
        await client.publish(m.topic, m.payload, qos=1, retain=m.retain)
        log.info("sim_published", extra={"topic": m.topic, "msg_id": m.msg_id, "kind": m.kind.value})
        sent.append(m)
    return sent


async def run_simulation(
    device: SimulatedDevice,
    broker: BrokerConfig,
    *,
    interval_s: float,
    count: int,
    pest_probability: float,
    harvest_probability: float,
    duplicate_every: int,
    rng: random.Random,
    silent_after: int = 0,
) -> int:
    """Publish ``count`` telemetry ticks (0 = forever) plus probabilistic events. Returns messages sent.

    ``silent_after`` > 0 simulates a device that is online but silent: after that many ticks it
    publishes nothing more - no telemetry, no events, no status - while its broker connection
    stays open (keep-alive continues, so no Last Will is published and the device stays "online").
    """
    sent = 0
    async with connect(device, broker) as client:
        await publish_all(client, [device.status("online")])
        tick = 0
        last: OutgoingMessage | None = None
        while count == 0 or tick < count:
            if silent_after and tick >= silent_after:
                if tick == silent_after:
                    log.info("sim_silent", extra={"device_id": device.device_id, "after_ticks": silent_after})
                tick += 1
                if count == 0 or tick < count:
                    await asyncio.sleep(interval_s)
                continue
            batch = [device.telemetry()]
            if rng.random() < pest_probability:
                pest = device.pest()
                batch += [pest, device.spray(related_msg_id=pest.msg_id)]
            if rng.random() < harvest_probability:
                batch.append(device.harvest())
            if duplicate_every and last is not None and tick % duplicate_every == 0:
                # Deliberate re-send of an already-published message to exercise idempotency.
                batch.append(last)
                log.info("sim_duplicate_resend", extra={"msg_id": last.msg_id})
            sent += len(await publish_all(client, batch))
            last = batch[0]
            tick += 1
            if count == 0 or tick < count:
                await asyncio.sleep(interval_s)
        # Graceful shutdown: publish offline explicitly (a clean disconnect does not fire the Will).
        sent += len(await publish_all(client, [device.status("offline")]))
    return sent
