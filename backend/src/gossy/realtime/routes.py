"""WebSocket endpoint ``/api/v1/ws`` - protocol ``gossy.ws.v1`` (see docs/websocket-contract.md).

Authentication: ``Authorization: Bearer <access token>`` on the upgrade request. A missing or
invalid token is rejected BEFORE the connection is accepted (HTTP 403 on the handshake).

Server → client: hello, event, resumed, resync_required, heartbeat, pong, error.
Client → server: ONLY ``start``, ``resume`` and ``ping``. Any other operation is answered with an
``unsupported_op`` error. This channel has no path to devices: the API process contains no
MQTT client and there are no command topics.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from datetime import UTC, datetime

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from gossy.auth.service import AuthFailed, Principal
from gossy.realtime.events import latest_cursor, load_events

log = logging.getLogger("gossy.realtime.ws")
router = APIRouter()

PROTOCOL = "gossy.ws.v1"
MAX_CLIENT_MESSAGE_BYTES = 4096
CLOSE_POLICY = 1008
CLOSE_TOO_BIG = 1009
CLOSE_AUTH = 4401
CLOSE_SLOW = 4008
ALLOWED_OPS = ("start", "resume", "ping")


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _bearer(websocket: WebSocket) -> str | None:
    scheme, _, token = websocket.headers.get("authorization", "").partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


@router.websocket("/api/v1/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    state = websocket.app.state
    token = _bearer(websocket)
    auth = getattr(state, "auth", None)
    principal = None
    if token and auth is not None:
        with contextlib.suppress(AuthFailed):
            principal = await auth.authenticate(token)
    if principal is None:
        log.info("ws_rejected", extra={"reason": "unauthenticated", "client": websocket.client.host if websocket.client else None})
        await websocket.close(code=CLOSE_POLICY)  # before accept -> handshake refused (HTTP 403)
        return
    await websocket.accept()
    await WsSession(websocket, principal, token).run()


class WsSession:
    def __init__(self, websocket: WebSocket, principal: Principal, token: str):
        self.ws = websocket
        self.principal = principal
        self.token = token
        state = websocket.app.state
        self.engine = state.engine
        self.hub = state.hub
        self.devices = state.devices
        self.auth = state.auth
        self.settings = state.api_settings
        self.sub = self.hub.subscribe()
        self.last_sent = 0
        self.live = asyncio.Event()
        self.lock = asyncio.Lock()
        self.close_code = 1000
        self.close_reason = ""

    async def send(self, message: dict) -> None:
        await self.ws.send_text(json.dumps(message, separators=(",", ":")))

    async def run(self) -> None:
        log.info("ws_connected", extra={"user": str(self.principal.user_id)})
        try:
            self.sub.allowed = await self.devices.accessible_device_ids(self.principal)
            await self.send({
                "type": "hello", "protocol": PROTOCOL, "serverTime": _now(),
                "latestCursor": await latest_cursor(self.engine, self.sub.allowed),
                "tokenExpiresAt": self.principal.token_expires_at.isoformat(),
                "heartbeatIntervalS": self.settings.ws_heartbeat_s,
                "allowedOps": list(ALLOWED_OPS),
            })
            tasks = [asyncio.create_task(c) for c in (self._reader(), self._writer(), self._heartbeat(), self._refresh(), self._expiry(), self._overflow())]
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for t in pending:
                t.cancel()
            for t in pending:
                with contextlib.suppress(asyncio.CancelledError, Exception):
                    await t
            for t in done:
                if not t.cancelled() and t.exception() and not isinstance(t.exception(), WebSocketDisconnect):
                    log.error("ws_task_failed", exc_info=t.exception())
                    self.close_code, self.close_reason = 1011, "internal_error"
        finally:
            self.hub.unsubscribe(self.sub)
            with contextlib.suppress(Exception):
                await self.ws.close(code=self.close_code, reason=self.close_reason)
            log.info("ws_disconnected", extra={"user": str(self.principal.user_id), "code": self.close_code, "reason": self.close_reason})

    # -------------------------------------------------------------- client -> server
    async def _reader(self) -> None:
        while True:
            text = await self.ws.receive_text()
            if len(text.encode()) > MAX_CLIENT_MESSAGE_BYTES:
                self.close_code, self.close_reason = CLOSE_TOO_BIG, "message_too_big"
                return
            try:
                msg = json.loads(text)
                op = msg.get("op") if isinstance(msg, dict) else None
            except json.JSONDecodeError:
                await self.send({"type": "error", "code": "invalid_message", "message": "Messages must be JSON objects."})
                continue
            if op == "ping":
                await self.send({"type": "pong", "serverTime": _now()})
            elif op == "start":
                if not self.live.is_set():
                    self.last_sent = await latest_cursor(self.engine, self.sub.allowed)
                    await self.send({"type": "resumed", "cursor": self.last_sent, "replayed": 0})
                    self.live.set()
            elif op == "resume":
                cursor = msg.get("cursor")
                if not isinstance(cursor, int) or isinstance(cursor, bool) or cursor < 0:
                    await self.send({"type": "error", "code": "invalid_cursor", "message": "cursor must be a non-negative integer."})
                elif self.live.is_set():
                    await self.send({"type": "error", "code": "already_started", "message": "resume is only allowed before the stream starts."})
                else:
                    await self._replay(cursor)
            else:
                await self.send({
                    "type": "error", "code": "unsupported_op",
                    "message": "Only 'start', 'resume' and 'ping' are supported. This channel is read-only and cannot send commands to devices.",
                })

    async def _replay(self, cursor: int) -> None:
        limit = self.settings.ws_replay_limit
        async with self.lock:
            events = await load_events(self.engine, self.sub.allowed, after=cursor, limit=limit + 1)
            if len(events) > limit:
                latest = await latest_cursor(self.engine, self.sub.allowed)
                await self.send({"type": "resync_required", "latestCursor": latest, "message": "Too many missed events; reload state via REST, then send start."})
                return
            self.last_sent = cursor
            for event in events:
                await self.send(event)
                self.last_sent = event["cursor"]
            await self.send({"type": "resumed", "cursor": self.last_sent, "replayed": len(events)})
            self.live.set()

    # -------------------------------------------------------------- server -> client
    async def _writer(self) -> None:
        await self.live.wait()
        while True:
            event = await self.sub.queue.get()
            async with self.lock:
                if event["cursor"] <= self.last_sent:
                    continue  # already delivered by replay
                await self.send(event)
                self.last_sent = event["cursor"]

    async def _heartbeat(self) -> None:
        while True:
            await asyncio.sleep(self.settings.ws_heartbeat_s)
            await self.send({"type": "heartbeat", "serverTime": _now(), "cursor": self.last_sent})

    async def _refresh(self) -> None:
        """Re-check the session (logout/revocation) and refresh device access periodically."""
        while True:
            await asyncio.sleep(self.settings.ws_refresh_s)
            try:
                await self.auth.authenticate(self.token)
            except AuthFailed:
                await self.send({"type": "error", "code": "session_revoked", "message": "Session is no longer valid."})
                self.close_code, self.close_reason = CLOSE_AUTH, "session_revoked"
                return
            self.sub.allowed = await self.devices.accessible_device_ids(self.principal)

    async def _expiry(self) -> None:
        remaining = (self.principal.token_expires_at - datetime.now(UTC)).total_seconds()
        await asyncio.sleep(max(0.0, remaining))
        await self.send({"type": "error", "code": "token_expired", "message": "Access token expired. Refresh it and reconnect with resume."})
        self.close_code, self.close_reason = CLOSE_AUTH, "token_expired"

    async def _overflow(self) -> None:
        await self.sub.overflowed.wait()
        self.close_code, self.close_reason = CLOSE_SLOW, "slow_consumer"
