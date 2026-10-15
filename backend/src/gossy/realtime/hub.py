"""Fan-out of events to connected WebSocket sessions, filtered per subscriber."""

from __future__ import annotations

import asyncio
import logging

from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.realtime.events import load_events

log = logging.getLogger("gossy.realtime.hub")
CATCH_UP_LIMIT = 1000


class Subscriber:
    def __init__(self, max_queue: int):
        self.queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=max_queue)
        self.allowed: set[str] = set()
        self.overflowed = asyncio.Event()

    def offer(self, event: dict) -> None:
        if event.get("deviceId") not in self.allowed:
            return
        try:
            self.queue.put_nowait(event)
        except asyncio.QueueFull:
            self.overflowed.set()  # the session closes; the client resumes from its last cursor


class EventHub:
    def __init__(self, engine: AsyncEngine, *, max_queue: int = 1000):
        self._engine = engine
        self._max_queue = max_queue
        self._subscribers: set[Subscriber] = set()
        self.last_cursor = 0

    def subscribe(self) -> Subscriber:
        sub = Subscriber(self._max_queue)
        self._subscribers.add(sub)
        return sub

    def unsubscribe(self, sub: Subscriber) -> None:
        self._subscribers.discard(sub)

    @property
    def subscriber_count(self) -> int:
        return len(self._subscribers)

    async def dispatch(self, event: dict) -> None:
        if event.get("truncated"):
            loaded = await load_events(self._engine, None, after=int(event["cursor"]) - 1, limit=1)
            if not loaded:
                return
            event = loaded[0]
        self.last_cursor = max(self.last_cursor, int(event.get("cursor", 0)))
        for sub in list(self._subscribers):
            sub.offer(event)

    async def catch_up(self) -> None:
        """After the listener (re)connects, deliver events committed while it was not listening."""
        missed = await load_events(self._engine, None, after=self.last_cursor, limit=CATCH_UP_LIMIT + 1)
        if len(missed) > CATCH_UP_LIMIT:
            log.warning("event_catch_up_overflow", extra={"after": self.last_cursor})
            for sub in list(self._subscribers):
                sub.overflowed.set()  # force clients to resume from their own cursor
            return
        for event in missed:
            await self.dispatch(event)
        log.info("event_catch_up", extra={"delivered": len(missed)})
