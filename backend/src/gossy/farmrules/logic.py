"""Pure farm-rules logic: database rows -> engine inputs -> advisories and farm status.

No I/O here (the store reads and writes, the worker fetches the forecast), so all of it is
unit-tested without a database. Mirrors bollbot/cloud/service.py.
"""

from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from functools import lru_cache

from pydantic.alias_generators import to_camel

from gossy.farmrules.core.config import load_etl, load_thresholds
from gossy.farmrules.core.engine import FarmReport, run_farm
from gossy.farmrules.core.models import (
    CLASSES, Advisory, AdvisoryType, ConfirmedDetection, ManualObservation, SegmentScan, TrapCount, WeatherReading,
)
from gossy.farmrules.core.rules import IST
from gossy.farmrules.weather import FarmWeather

log = logging.getLogger("gossy.farmrules")

HISTORY_DAYS = 14  # inputs older than this are not loaded
WEATHER_MAX_AGE = timedelta(hours=3)  # a cached forecast older than this is not used
CART_WEATHER_MAX_AGE = timedelta(hours=2)  # the cart's own air reading is preferred while this fresh
NOTIFY_COOLDOWN = timedelta(hours=12)
RENOTIFY = {AdvisoryType.PICK_NOW}  # still active after the cooldown -> notify again

# Scan counts arrive in contract (camelCase) form: bollClosed -> boll_closed.
_COUNT_KEYS = {to_camel(c): c for c in CLASSES}


@lru_cache(maxsize=1)
def config() -> tuple[dict, dict]:
    """(thresholds, pests) from the copied bollbot config files. Validated on first use."""
    return load_thresholds(), load_etl()


def farm_key(farm_id: uuid.UUID | str) -> str:
    return str(farm_id)


def ist_today(now: datetime) -> date:
    return now.astimezone(IST).date()


# ----------------------------------------------------------------------------- inputs
def scan_from_event(farm: str, time: datetime, data: dict) -> SegmentScan:
    """One event/scan message (validated ScanEventData in wire form) as an engine scan."""
    counts = {_COUNT_KEYS[k]: int(v) for k, v in (data.get("counts") or {}).items()}
    weather = None
    t, rh = data.get("airTempC"), data.get("airRhPct")
    if t is not None and rh is not None and rh > 0:  # dew point is undefined at 0 % RH
        weather = WeatherReading(float(t), float(rh), data.get("dewpointC"))
    return SegmentScan(
        farm=farm, row=int(data["row"]), segment=int(data["segment"]), ts=time, counts=counts,
        model=str(data.get("model", "")), weather=weather,
    )


@dataclass
class FarmInputs:
    scans: list[SegmentScan] = field(default_factory=list)
    traps: list[TrapCount] = field(default_factory=list)
    manual: list[ManualObservation] = field(default_factory=list)
    confirmed: list[ConfirmedDetection] = field(default_factory=list)


def scans_from_events(farm: str, rows) -> list[SegmentScan]:
    """``rows``: (time, data) pairs. A malformed scan is skipped and logged, never fatal."""
    out = []
    for time, data in rows:
        try:
            out.append(scan_from_event(farm, time, data))
        except (KeyError, TypeError, ValueError) as exc:
            log.warning("farmrules_scan_skipped", extra={"farm_id": farm, "error": str(exc)})
    return out


# ----------------------------------------------------------------------------- compute
@dataclass
class Computed:
    report: FarmReport
    weather: FarmWeather | None  # the forecast used (fresh enough), if any
    weather_now: WeatherReading | None
    weather_source: str | None  # "cart" | "forecast" | None


def usable_weather(cached: FarmWeather | None, now: datetime) -> FarmWeather | None:
    if cached is None:
        return None
    fetched = cached.fetched if cached.fetched.tzinfo else cached.fetched.replace(tzinfo=IST)
    return cached if now - fetched <= WEATHER_MAX_AGE else None


def compute(farm: str, now: datetime, inputs: FarmInputs, cached_weather: FarmWeather | None,
            thresholds: dict | None = None, pests: dict | None = None) -> Computed:
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    if thresholds is None or pests is None:
        thresholds, pests = config()
    fw = usable_weather(cached_weather, now)
    # Picking window: the cart's own sensor if it read recently, else the forecast model.
    recent = [s for s in inputs.scans if s.weather and timedelta(0) <= now - s.ts <= CART_WEATHER_MAX_AGE]
    if recent:
        weather_now, source = max(recent, key=lambda s: s.ts).weather, "cart"
    elif fw and fw.now_reading:
        weather_now, source = fw.now_reading, "forecast"
    else:
        weather_now, source = None, None
    report = run_farm(
        farm, now, thresholds, pests, scans=inputs.scans, traps=inputs.traps, manual=inputs.manual,
        confirmed=inputs.confirmed, weather_now=weather_now,
        rain_last_24h_mm=fw.rain_last_24h_mm if fw else 0.0, forecast=fw.forecast if fw else (),
    )
    return Computed(report, fw, weather_now, source)


# ----------------------------------------------------------------------------- advisories
def advisory_key(a: Advisory) -> str:
    """One active advisory per farm, type and pest. It is updated while the condition lasts and
    resolved when it clears; if it comes back later, that is a new advisory."""
    return f"{a.type.value}:{a.pest or 'crop'}"


@dataclass(frozen=True)
class ActiveAdvisory:
    id: uuid.UUID
    key: str
    segments: tuple[str, ...]
    reason: str
    notified_at: datetime | None


@dataclass
class Plan:
    create: list[tuple[str, Advisory]] = field(default_factory=list)  # new -> notify
    update: list[tuple[uuid.UUID, Advisory, bool]] = field(default_factory=list)  # (id, advisory, notify again)
    resolve: list[uuid.UUID] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        return not (self.create or self.update or self.resolve)


def reconcile(active: dict[str, ActiveAdvisory], new: list[Advisory], now: datetime) -> Plan:
    """Compare the engine's advisories with the farm's active ones.

    - new key                                -> create (notify)
    - same key, segments or reason changed    -> update
    - PICK_NOW still active after the cooldown -> update and notify again
    - same key, unchanged                     -> nothing
    - active key not produced now             -> resolve
    """
    plan = Plan()
    seen = set()
    for a in new:
        key = advisory_key(a)
        seen.add(key)
        old = active.get(key)
        if old is None:
            plan.create.append((key, a))
            continue
        changed = sorted(old.segments) != sorted(a.segments) or old.reason != a.reason
        renotify = a.type in RENOTIFY and (old.notified_at is None or now - old.notified_at >= NOTIFY_COOLDOWN)
        if changed or renotify:
            plan.update.append((old.id, a, renotify))
    plan.resolve = [old.id for key, old in active.items() if key not in seen]
    return plan


# ----------------------------------------------------------------------------- status
def _segment_parts(key: str) -> tuple[int, int]:
    row, seg = key.split("-")  # "R003-S02"
    return int(row[1:]), int(seg[1:])


def status_doc(c: Computed, now: datetime) -> dict:
    """The farm status document (snake_case; the API serialises it as camelCase FarmStatus)."""
    report, fw = c.report, c.weather
    w = report.window
    horizon = now + timedelta(hours=48)
    segments = []
    for s in report.segments:
        row, seg = _segment_parts(s.segment)
        segments.append({
            "key": s.segment, "row": row, "segment": seg, "readiness": s.readiness, "status": s.status.value,
            "open_bolls": s.open_bolls, "scanned_at": s.scanned.isoformat(),
        })
    return {
        "computed_at": now.isoformat(),
        "segments": segments,
        "window": None if w is None else {
            "status": w.status.value, "dewpoint_c": w.dewpoint_c, "dewpoint_depression_c": w.dewpoint_depression_c,
            "reasons": list(w.failed),
        },
        "weather_now": None if c.weather_now is None else {
            "air_temp_c": c.weather_now.t_c, "air_rh_pct": c.weather_now.rh,
            "dewpoint_c": c.weather_now.dewpoint_c if c.weather_now.dewpoint_c is not None else (w.dewpoint_c if w else None),
            "source": c.weather_source,
        },
        "forecast_fetched_at": fw.fetched.isoformat() if fw else None,
        "rain_last_24h_mm": fw.rain_last_24h_mm if fw else None,
        "rain_max_prob_48h_pct": max((p for t, p in fw.forecast if now <= t <= horizon), default=None) if fw else None,
        "pests": [
            {"pest": f.pest, "crossed": f.crossed, "insufficient": f.insufficient, "value": f.value,
             "threshold": f.threshold, "action": f.action, "detail": f.detail, "segments": list(f.segments)}
            for f in report.findings
        ],
    }


# ----------------------------------------------------------------------------- catalog
_UNIT_WORD = {"mean_per_unit": "per unit", "percent_units": "% of units", "presence": "count"}


def observation_rules(pests: dict | None = None) -> dict[str, dict]:
    """Scouting observation key -> the pest rule that uses it (one rule per key)."""
    if pests is None:
        pests = config()[1]
    return {r["observation"]: {"pest": k, **r} for k, r in pests.items() if "observation" in r}


def trap_prefixes(pests: dict | None = None) -> set[str]:
    if pests is None:
        pests = config()[1]
    return {r["trap_prefix"].upper() for r in pests.values() if r.get("type") == "consecutive_nights"}


def catalog(pests: dict | None = None) -> list[dict]:
    """Every pest rule, for the app's scouting form and for showing thresholds with sources."""
    if pests is None:
        pests = config()[1]
    out = []
    for key, r in pests.items():
        out.append({
            "pest": key, "name_en": r.get("name_en", key), "name_ta": r.get("name_ta", ""), "rule_type": r["type"],
            "evidence": r.get("source") or ("camera" if r["type"] == "camera_ratio" else "manual"),
            "observation": r.get("observation"), "trap_prefix": r.get("trap_prefix"),
            "threshold": float(r["threshold"]), "comparison": ">" if r.get("strict") else ">=",
            "min_units": r.get("min_units"), "nights": r.get("nights"), "action": r["action"],
        })
    return out
