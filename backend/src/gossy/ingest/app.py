"""Ingest service entry point: ``uvicorn --factory gossy.ingest.app:create_app``.

Runs the MQTT consumer as a background task and exposes /healthz and /readyz (database
reachable + broker connected) plus ingestion counters for observability.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from datetime import UTC, datetime
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from gossy import __version__
from gossy.api.middleware import RequestContextMiddleware
from gossy.config import CommonSettings, DatabaseSettings, IngestSettings, MqttSettings, enforce_environment_rules
from gossy.db.engine import create_engine
from gossy.health.checks import CheckResult, database_check, named
from gossy.health.routes import router as health_router
from gossy.ingest.consumer import MqttConsumer
from gossy.health.metrics import database_up
from gossy.health.metrics import router as metrics_router
from gossy.ingest.faults import FaultInjector
from gossy.ingest.metrics import ingest_metrics
from gossy.ingest.service import ingest_condition
from gossy.ingest.repository import SqlIngestRepository
from gossy.ingest.service import IngestService
from gossy.logging_setup import configure_logging

log = logging.getLogger("gossy.ingest")


def create_app() -> FastAPI:
    common = CommonSettings()
    db = DatabaseSettings()
    mqtt = MqttSettings()
    ingest = IngestSettings()
    configure_logging(common.log_level, json_output=common.log_json)
    enforce_environment_rules(common, secret_files=[db.password_file, mqtt.password_file], ingest=ingest)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        engine = create_engine(db)
        faults = FaultInjector(ingest.fault_injection_dir)
        service = IngestService(SqlIngestRepository(engine, faults), ingest)
        consumer = MqttConsumer(mqtt, service.handle, faults)

        async def mqtt_check() -> CheckResult:
            return CheckResult("mqtt", consumer.connected, "connected" if consumer.connected else "not connected")

        app.state.readiness_checks = [database_check(engine), named("mqtt", mqtt_check)]
        app.state.readiness_info = lambda: {
            "ingest": service.stats.snapshot(),
            "mqtt_connect_count": consumer.connect_count,
            "mqtt_acked": consumer.acked,
            "mqtt_ack_failures": consumer.ack_failures,
            "fault_injection": faults.enabled,
            "condition": ingest_condition(service.stats, datetime.now(UTC), ingest.retry_prolonged_after_s),
        }
        async def metrics_source():
            return [*ingest_metrics(service, consumer, ingest.retry_prolonged_after_s), await database_up(engine)]

        app.state.metrics_source = metrics_source
        task = asyncio.create_task(consumer.run(), name="mqtt-consumer")
        log.info("ingest_started", extra={"environment": common.environment, "version": __version__, "fault_injection": faults.enabled})
        try:
            yield
        finally:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
            await engine.dispose()
            log.info("ingest_stopped", extra={"stats": service.stats.snapshot()})

    app = FastAPI(title="Smart Gossyculture Ingest", version=__version__, docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.add_middleware(RequestContextMiddleware)
    app.include_router(health_router)
    app.include_router(metrics_router)
    return app
