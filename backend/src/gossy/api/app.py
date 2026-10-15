"""API service entry point: ``uvicorn --factory gossy.api.app:create_app``.

Serves the versioned REST API (/api/v1), the live-monitoring WebSocket (/api/v1/ws) and health
probes. The API process deliberately contains NO MQTT client: it reads from the database and
cannot send anything to devices (v1 monitoring-only boundary).
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from gossy import __version__
from gossy.alerts.routes import router as alerts_router
from gossy.api.errors import install_error_handlers
from gossy.api.middleware import BodySizeLimitMiddleware, RequestContextMiddleware
from gossy.auth.routes import router as auth_router
from gossy.auth.service import AuthService
from gossy.config import ApiSettings, AuthSettings, CommonSettings, DatabaseSettings, enforce_environment_rules
from gossy.db.engine import create_engine
from gossy.db.migrations import expected_head
from gossy.devices.routes import router as devices_router
from gossy.devices.service import DeviceService
from gossy.farmrules.routes import router as farmrules_router
from gossy.farmrules.store import FarmRulesStore
from gossy.health.checks import CheckResult, ReadinessCheck, database_check, migrations_check, named, timescaledb_check
from gossy.health.metrics import Metric, database_up
from gossy.health.metrics import router as metrics_router
from gossy.health.routes import router as health_router
from gossy.logging_setup import configure_logging
from gossy.realtime.events import latest_cursor
from gossy.realtime.hub import EventHub
from gossy.realtime.listener import PgEventListener, conninfo
from gossy.realtime.routes import router as ws_router
from gossy.security.otp import TestOtpIssuer, UnavailableOtpIssuer
from gossy.security.tokens import AccessTokenService
from gossy.telemetry.routes import router as telemetry_router

log = logging.getLogger("gossy.api")

DESCRIPTION = """
Backend API for Smart Gossyculture / BOLLBOT (v1, **monitoring-only**).

**Authentication.** Phone one-time code → `POST /api/v1/auth/otp/request`, then
`POST /api/v1/auth/otp/verify` returns a short-lived access token (JWT, `Authorization: Bearer …`)
and a single-use refresh token (`POST /api/v1/auth/refresh` rotates it; reuse revokes the session).
Development/staging use allow-listed test numbers with a fixed code; no SMS is sent. Real SMS
delivery is not implemented (provider undecided).

**Authorization.** Farmers see only devices attached to farms they own; other resources answer 404.
A farm's owner can add operators, who read the farm's advice and enter trap, scouting and
confirmation data, but cannot see its devices. Admin endpoints (`/api/v1/admin/...`) handle
device provisioning only.

**Farm rules.** Advice (harvest readiness per row segment, picking window, rain alert, pest
thresholds with spray blocking) is computed from cart scans and entered data by the published
rules in `bollbot/config`; see `docs/farm-rules.md`. Advice never triggers a device.

**Errors.** Every error body is `{"error": {"code", "message", "requestId", "details?"}}`.

**Live updates.** `GET /api/v1/ws` (WebSocket, protocol `gossy.ws.v1`) streams events and alerts to
authorized clients; see `docs/websocket-contract.md`. It accepts only `start`, `resume` and `ping`.

**No device control.** There is no endpoint, WebSocket operation or MQTT topic that sends commands
to devices. Harvesting and spraying are never triggered by this API.
"""

TAGS = [
    {"name": "auth", "description": "Phone OTP sign-in, token refresh, logout"},
    {"name": "profile", "description": "The signed-in user"},
    {"name": "farms", "description": "Farms owned by the signed-in user"},
    {"name": "devices", "description": "Device registry view, status and claim (read-only; no control)"},
    {"name": "telemetry", "description": "Persisted telemetry and device events"},
    {"name": "detections", "description": "Pest/disease detections reported by the upstream device detector"},
    {"name": "alerts", "description": "Alerts derived from device messages"},
    {"name": "farm-rules", "description": "Advice from the farm rules (harvest readiness, picking window, rain alert, pest thresholds) and the data they use: trap counts, scouting counts, checked detections"},
    {"name": "admin", "description": "Device provisioning (admin role)"},
    {"name": "health", "description": "Liveness and readiness probes"},
]


def create_app(
    *,
    common: CommonSettings | None = None,
    api: ApiSettings | None = None,
    db: DatabaseSettings | None = None,
    auth: AuthSettings | None = None,
    readiness_checks: list[ReadinessCheck] | None = None,
) -> FastAPI:
    """Build the API.

    ``readiness_checks`` given => no database is used (unit tests, OpenAPI export): routes exist
    but data endpoints answer 503.
    """
    common = common or CommonSettings()
    api = api or ApiSettings()
    configure_logging(common.log_level, json_output=common.log_json)
    offline = readiness_checks is not None
    if not offline:
        db = db or DatabaseSettings()
        auth = auth or AuthSettings()
        enforce_environment_rules(common, secret_files=[db.password_file], api=api, auth=auth)
    else:
        enforce_environment_rules(common, api=api)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        app.state.api_settings = api
        if offline:
            app.state.readiness_checks = readiness_checks
            yield
            return
        engine = create_engine(db)
        tokens = AccessTokenService(auth.jwt_signing_key(), issuer=auth.issuer, audience=auth.audience, ttl_s=auth.access_token_ttl_s)
        issuer = TestOtpIssuer(auth.test_phones(), auth.test_otp_code()) if auth.test_mode else UnavailableOtpIssuer()
        hub = EventHub(engine, max_queue=api.ws_queue_size)
        hub.last_cursor = await latest_cursor(engine, None)
        listener = PgEventListener(conninfo(db), hub.dispatch, hub.catch_up)
        app.state.engine = engine
        app.state.auth = AuthService(engine, auth, tokens, issuer)
        app.state.devices = DeviceService(
            engine, auth.otp_hmac_key(), claim_code_ttl_s=api.claim_code_ttl_s, claim_attempts_per_user=api.claim_attempts_per_user,
            telemetry_interval_s=api.telemetry_interval_s, telemetry_stale_after_s=api.telemetry_stale_after_s,
        )
        app.state.hub = hub
        app.state.farmrules = FarmRulesStore(engine)

        async def listener_check() -> CheckResult:
            return CheckResult("event_listener", listener.connected, "listening" if listener.connected else "not connected")

        app.state.readiness_checks = [
            database_check(engine), timescaledb_check(engine), migrations_check(engine, expected_head()), named("event_listener", listener_check),
        ]
        app.state.readiness_info = lambda: {"otpMode": issuer.mode, "websocketSubscribers": hub.subscriber_count, "lastEventCursor": hub.last_cursor}

        api_metrics = lambda: [  # noqa: E731
            Metric("gossy_api_http_requests_total", "counter", "HTTP requests by status class", [({"status": k}, v) for k, v in sorted(http_counters.items())]),
            Metric.single("gossy_api_unhandled_errors_total", "counter", "Unhandled application errors (HTTP 500)", getattr(app.state, "unhandled_errors", 0)),
            Metric.single("gossy_api_websocket_subscribers", "gauge", "Connected WebSocket sessions", hub.subscriber_count),
            Metric.single("gossy_api_event_listener_connected", "gauge", "1 if the PostgreSQL LISTEN connection is up", 1.0 if listener.connected else 0.0),
            Metric.single("gossy_api_event_listener_connects_total", "counter", "LISTEN (re)connections", listener.connect_count),
            Metric.single("gossy_api_last_event_cursor", "gauge", "Highest event cursor dispatched", hub.last_cursor),
        ]

        async def metrics_source():
            return [*api_metrics(), await database_up(engine)]

        app.state.metrics_source = metrics_source
        task = asyncio.create_task(listener.run(), name="event-listener")
        log.info("api_started", extra={"environment": common.environment, "version": __version__, "otp_mode": issuer.mode})
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            await engine.dispose()
            log.info("api_stopped")

    app = FastAPI(
        title="Smart Gossyculture API",
        version=__version__,
        description=DESCRIPTION,
        openapi_tags=TAGS,
        docs_url="/docs" if api.docs_enabled else None,
        redoc_url=None,
        openapi_url="/openapi.json" if api.docs_enabled else None,
        lifespan=lifespan,
    )
    install_error_handlers(app)
    http_counters: dict[str, int] = {}
    app.add_middleware(BodySizeLimitMiddleware, max_bytes=api.max_request_body_bytes)
    app.add_middleware(RequestContextMiddleware, counters=http_counters)
    for router in (health_router, metrics_router, auth_router, devices_router, telemetry_router, alerts_router, farmrules_router, ws_router):
        app.include_router(router)
    return app
