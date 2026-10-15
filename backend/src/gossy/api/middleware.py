"""Pure ASGI middleware: request ID propagation, one structured log line per request, baseline
response headers, and a request-body size limit."""

from __future__ import annotations

import json
import logging
import re
import time

from starlette.exceptions import HTTPException

from gossy.ids import new_ulid
from gossy.logging_setup import request_id_var

log = logging.getLogger("gossy.http")
_VALID_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{8,64}$")
HEADER = b"x-request-id"
# API responses are per-user data: never cache, never MIME-sniff.
_SECURITY_HEADERS = [(b"cache-control", b"no-store"), (b"x-content-type-options", b"nosniff")]


class RequestContextMiddleware:
    def __init__(self, app, counters: dict[str, int] | None = None):
        self.app = app
        # Optional per-status-class request counters ("2xx", "4xx", "5xx", ...) for /metrics.
        self.counters = counters

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = dict(scope.get("headers") or []).get(HEADER, b"").decode("latin-1")
        request_id = incoming if _VALID_REQUEST_ID.match(incoming) else new_ulid()
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        status = 500

        async def send_with_id(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                headers = [h for h in message.get("headers", []) if h[0].lower() != b"cache-control"]
                message["headers"] = [*headers, (HEADER, request_id.encode("latin-1")), *_SECURITY_HEADERS]
            await send(message)

        try:
            await self.app(scope, receive, send_with_id)
        finally:
            if self.counters is not None:
                key = f"{status // 100}xx"
                self.counters[key] = self.counters.get(key, 0) + 1
            log.info(
                "http_request",
                extra={
                    "method": scope.get("method"),
                    "path": scope.get("path"),
                    "status": status,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 1),
                },
            )
            request_id_var.reset(token)


class BodySizeLimitMiddleware:
    """Reject request bodies above ``max_bytes`` (declared or streamed) with 413."""

    def __init__(self, app, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        declared = dict(scope.get("headers") or []).get(b"content-length")
        if declared is not None and declared.isdigit() and int(declared) > self.max_bytes:
            await _too_large(send)
            return

        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    raise _BodyTooLarge
            return message

        try:
            await self.app(scope, limited_receive, send)
        except _BodyTooLarge:
            await _too_large(send)


class _BodyTooLarge(HTTPException):
    """Raised while the app reads a streamed (chunked) body; FastAPI's handlers answer 413."""

    def __init__(self):
        super().__init__(status_code=413, detail="Request body too large.")


async def _too_large(send) -> None:
    body = json.dumps({"error": {"code": "payload_too_large", "message": "Request body too large.", "requestId": request_id_var.get()}}).encode()
    await send({"type": "http.response.start", "status": 413, "headers": [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]})
    await send({"type": "http.response.body", "body": body})
