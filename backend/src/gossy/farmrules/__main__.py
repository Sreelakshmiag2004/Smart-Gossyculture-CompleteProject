"""Farm-rules worker entry point: ``python -m gossy.farmrules``.

Needs only the database (runtime role) and outbound HTTPS to Open-Meteo. No MQTT, no device
access. Set GOSSY_FARMRULES_WEATHER_ENABLED=false where the internet is not reachable.
"""

from __future__ import annotations

import asyncio
import logging
import signal

import httpx

from gossy import __version__
from gossy.config import CommonSettings, DatabaseSettings, FarmRulesSettings, enforce_environment_rules
from gossy.db.engine import create_engine
from gossy.farmrules import weather
from gossy.farmrules.logic import config
from gossy.farmrules.store import FarmRulesStore
from gossy.farmrules.worker import FarmRulesWorker
from gossy.logging_setup import configure_logging

log = logging.getLogger("gossy.farmrules")


async def main() -> None:
    common, db, settings = CommonSettings(), DatabaseSettings(), FarmRulesSettings()
    configure_logging(common.log_level, json_output=common.log_json)
    enforce_environment_rules(common, secret_files=[db.password_file])
    config()  # fail at start-up, not at the first farm, if a threshold file is invalid
    engine = create_engine(db)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    async with httpx.AsyncClient(timeout=settings.weather_timeout_s) as client:
        async def fetch(lat, lon, now):
            return await weather.fetch(client, lat, lon, now, settings.weather_api_url)

        worker = FarmRulesWorker(FarmRulesStore(engine), settings, fetch)
        log.info("farmrules_started", extra={"version": __version__, "interval_s": settings.interval_s, "weather": settings.weather_enabled})
        task = asyncio.create_task(worker.run(), name="farmrules")
        await stop.wait()
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
    await engine.dispose()
    log.info("farmrules_stopped", extra={"runs": worker.runs, "failures": worker.failures})


if __name__ == "__main__":
    asyncio.run(main())
