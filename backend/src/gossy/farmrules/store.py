"""Database access for the farm rules: load one farm's inputs, apply the advisory plan, save
the status and the forecast cache. Every recompute runs in ONE transaction under a per-farm
advisory lock, so the API (after data entry) and the worker never race on the same farm."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, select, text, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from gossy.db.tables import (
    detection_confirmations, device_events, devices, farm_advisories, farm_status, farm_weather, farms,
    scouting_observations, trap_counts,
)
from gossy.farmrules import logic
from gossy.farmrules.core.models import ConfirmedDetection, ManualObservation, TrapCount
from gossy.farmrules.weather import FarmWeather

REASON_MAX = 512


def _now() -> datetime:
    return datetime.now(UTC)


async def _lock(conn: AsyncConnection, farm_id: uuid.UUID) -> None:
    await conn.execute(text("SELECT pg_advisory_xact_lock(hashtext(:k))"), {"k": f"farmrules:{farm_id}"})


async def load_inputs(conn: AsyncConnection, farm_id: uuid.UUID, now: datetime) -> logic.FarmInputs:
    farm = logic.farm_key(farm_id)
    since = now - timedelta(days=logic.HISTORY_DAYS)
    since_day = logic.ist_today(since)
    # Scans of every device currently attached to the farm (the farm comes from the registry,
    # never from the device).
    farm_devices = select(devices.c.device_id).where(devices.c.farm_id == farm_id)
    scan_rows = await conn.execute(
        select(device_events.c.time, device_events.c.data).where(and_(
            device_events.c.event_type == "scan", device_events.c.device_id.in_(farm_devices),
            device_events.c.time >= since, device_events.c.time <= now,
        ))
    )
    traps = await conn.execute(
        select(trap_counts.c.trap, trap_counts.c.night, trap_counts.c.moths).where(and_(
            trap_counts.c.farm_id == farm_id, trap_counts.c.deleted_at.is_(None), trap_counts.c.night >= since_day,
        ))
    )
    manual = await conn.execute(
        select(scouting_observations.c.observed_on, scouting_observations.c.observation, scouting_observations.c.count, scouting_observations.c.units).where(and_(
            scouting_observations.c.farm_id == farm_id, scouting_observations.c.deleted_at.is_(None), scouting_observations.c.observed_on >= since_day,
        ))
    )
    confirmed = await conn.execute(
        select(detection_confirmations.c.row_no, detection_confirmations.c.segment_no, detection_confirmations.c.class_name, detection_confirmations.c.observed_on).where(and_(
            detection_confirmations.c.farm_id == farm_id, detection_confirmations.c.deleted_at.is_(None),
            detection_confirmations.c.verdict == "confirmed", detection_confirmations.c.observed_on >= since_day,
        ))
    )
    return logic.FarmInputs(
        scans=logic.scans_from_events(farm, [(r.time, r.data) for r in scan_rows]),
        traps=[TrapCount(farm, r.trap, r.night, r.moths) for r in traps],
        manual=[ManualObservation(farm, r.observed_on, r.observation, r.count, r.units) for r in manual],
        confirmed=[ConfirmedDetection(farm, r.row_no, r.segment_no, r.class_name, r.observed_on) for r in confirmed],
    )


async def load_weather(conn: AsyncConnection, farm_id: uuid.UUID) -> FarmWeather | None:
    row = (await conn.execute(select(farm_weather.c.doc).where(farm_weather.c.farm_id == farm_id))).first()
    if row is None:
        return None
    try:
        return FarmWeather.from_doc(row.doc)
    except (KeyError, TypeError, ValueError):
        logic.log.warning("farmrules_bad_weather_cache", extra={"farm_id": str(farm_id)})
        return None


async def load_active(conn: AsyncConnection, farm_id: uuid.UUID) -> dict[str, logic.ActiveAdvisory]:
    rows = await conn.execute(select(farm_advisories).where(and_(farm_advisories.c.farm_id == farm_id, farm_advisories.c.active)))
    return {r.key: logic.ActiveAdvisory(r.id, r.key, tuple(r.segments or ()), r.reason, r.notified_at) for r in rows}


def _advisory_values(a) -> dict:
    return {
        "type": a.type.value, "pest": a.pest, "reason": a.reason[:REASON_MAX], "segments": list(a.segments),
        "text_en": a.text_en, "text_ta": a.text_ta,
    }


async def apply_plan(conn: AsyncConnection, farm_id: uuid.UUID, plan: logic.Plan, now: datetime) -> None:
    for advisory_id in plan.resolve:
        await conn.execute(update(farm_advisories).where(farm_advisories.c.id == advisory_id).values(active=False, resolved_at=now, updated_at=now))
    for key, a in plan.create:
        await conn.execute(farm_advisories.insert().values(
            farm_id=farm_id, key=key, active=True, created_at=now, updated_at=now, notified_at=now, **_advisory_values(a),
        ))
    for advisory_id, a, renotify in plan.update:
        values = {**_advisory_values(a), "updated_at": now}
        if renotify:
            values["notified_at"] = now
        await conn.execute(update(farm_advisories).where(farm_advisories.c.id == advisory_id).values(**values))


class FarmRulesStore:
    def __init__(self, engine: AsyncEngine, *, clock: Callable[[], datetime] = _now):
        self.engine = engine
        self._clock = clock

    async def recompute(self, farm_id: uuid.UUID, now: datetime | None = None) -> dict:
        """Run the rules for one farm and persist advisories and status. Returns the status doc."""
        now = now or self._clock()
        async with self.engine.begin() as conn:
            await _lock(conn, farm_id)
            inputs = await load_inputs(conn, farm_id, now)
            computed = logic.compute(logic.farm_key(farm_id), now, inputs, await load_weather(conn, farm_id))
            plan = logic.reconcile(await load_active(conn, farm_id), computed.report.advisories, now)
            await apply_plan(conn, farm_id, plan, now)
            doc = logic.status_doc(computed, now)
            await conn.execute(
                pg_insert(farm_status).values(farm_id=farm_id, computed_at=now, doc=doc)
                .on_conflict_do_update(index_elements=["farm_id"], set_={"computed_at": now, "doc": doc})
            )
        if not plan.empty:
            logic.log.info("farmrules_advisories_changed", extra={
                "farm_id": str(farm_id), "created": [k for k, _ in plan.create], "updated": len(plan.update), "resolved": len(plan.resolve),
            })
        return doc

    async def save_weather(self, farm_id: uuid.UUID, fw: FarmWeather) -> None:
        doc = fw.to_doc()
        async with self.engine.begin() as conn:
            await conn.execute(
                pg_insert(farm_weather).values(farm_id=farm_id, fetched_at=fw.fetched, doc=doc)
                .on_conflict_do_update(index_elements=["farm_id"], set_={"fetched_at": fw.fetched, "doc": doc})
            )

    async def farms(self) -> list:
        """Every farm with its location and the age of its cached forecast (for the worker)."""
        async with self.engine.connect() as conn:
            rows = await conn.execute(
                select(farms.c.id, farms.c.latitude, farms.c.longitude, farm_weather.c.fetched_at)
                .select_from(farms.outerjoin(farm_weather, farm_weather.c.farm_id == farms.c.id))
                .order_by(farms.c.created_at)
            )
            return list(rows)
