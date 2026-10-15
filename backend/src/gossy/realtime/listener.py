"""PostgreSQL LISTEN loop (API process). NOTIFY is transactional: an event is only published
after the ingest transaction that stored it has committed."""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable

import psycopg
from psycopg.conninfo import make_conninfo

from gossy.config import DatabaseSettings
from gossy.realtime.events import CHANNEL

log = logging.getLogger("gossy.realtime.listener")


def conninfo(db: DatabaseSettings) -> str:
    return make_conninfo(
        host=db.host, port=db.port, dbname=db.name, user=db.user, password=db.password_value(),
        connect_timeout=db.connect_timeout_s, application_name="gossy-api-listener",
    )


class PgEventListener:
    def __init__(self, dsn: str, on_event: Callable[[dict], Awaitable[None]], on_connect: Callable[[], Awaitable[None]]):
        self._dsn = dsn
        self._on_event = on_event
        self._on_connect = on_connect
        self.connected = False
        self.connect_count = 0

    async def run(self) -> None:
        delay = 1.0
        while True:
            try:
                async with await psycopg.AsyncConnection.connect(self._dsn, autocommit=True) as conn:
                    await conn.execute(f"LISTEN {CHANNEL}")
                    self.connected = True
                    self.connect_count += 1
                    delay = 1.0
                    log.info("event_listener_connected", extra={"channel": CHANNEL, "connect_count": self.connect_count})
                    # Deliver anything committed while we were not listening: before a reconnect,
                    # and on the first connect since API startup (the hub's starting cursor was
                    # read before LISTEN was issued).
                    await self._on_connect()
                    async for notification in conn.notifies():
                        try:
                            event = json.loads(notification.payload)
                        except json.JSONDecodeError:
                            log.warning("event_payload_invalid")
                            continue
                        await self._on_event(event)
            except asyncio.CancelledError:
                self.connected = False
                raise
            except Exception as exc:
                self.connected = False
                log.warning("event_listener_disconnected", extra={"error_type": type(exc).__name__, "retry_in_s": delay})
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30.0)
