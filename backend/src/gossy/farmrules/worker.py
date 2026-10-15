"""Farm-rules worker loop: forecast refresh (hourly, per farm with a location) and a recompute of
every farm (every minute). One farm's failure never stops the others; a forecast failure never
stops the pest rules (they do not need weather)."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime, timedelta

from gossy.config import FarmRulesSettings
from gossy.farmrules.weather import FarmWeather

log = logging.getLogger("gossy.farmrules")

Fetch = Callable[[float, float, datetime], Awaitable[FarmWeather]]


def _now() -> datetime:
    return datetime.now(UTC)


class FarmRulesWorker:
    def __init__(self, store, settings: FarmRulesSettings, fetch: Fetch | None, *,
                 clock: Callable[[], datetime] = _now, sleep: Callable[[float], Awaitable[None]] = asyncio.sleep):
        self._store = store
        self._settings = settings
        self._fetch = fetch if settings.weather_enabled else None
        self._clock = clock
        self._sleep = sleep
        self.runs = 0
        self.failures = 0

    def _needs_weather(self, farm, now: datetime) -> bool:
        if self._fetch is None or farm.latitude is None or farm.longitude is None:
            return False
        return farm.fetched_at is None or now - farm.fetched_at >= timedelta(seconds=self._settings.weather_refresh_s)

    async def run_once(self) -> None:
        now = self._clock()
        for farm in await self._store.farms():
            if self._needs_weather(farm, now):
                try:
                    await self._store.save_weather(farm.id, await self._fetch(farm.latitude, farm.longitude, now))
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # noqa: BLE001 - no forecast must not stop pest advice
                    log.warning("farmrules_weather_failed", extra={"farm_id": str(farm.id), "error_type": type(exc).__name__})
            try:
                await self._store.recompute(farm.id, now)
            except asyncio.CancelledError:
                raise
            except Exception:
                self.failures += 1
                log.exception("farmrules_recompute_failed", extra={"farm_id": str(farm.id)})
        self.runs += 1

    async def run(self) -> None:
        while True:
            try:
                await self.run_once()
            except asyncio.CancelledError:
                raise
            except Exception:  # database down: try again next interval
                self.failures += 1
                log.exception("farmrules_run_failed")
            await self._sleep(self._settings.interval_s)
