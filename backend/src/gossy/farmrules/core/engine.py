"""Run every rule for one farm and return the advisories to publish.

This is the function the cloud rules engine (Module 4) calls on each new
scan, trap count or forecast update. It is pure: same inputs, same output.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Iterable, Optional

from . import rules
from .etl import EtlInputs, PestFinding, evaluate
from .messages import fill_text
from .models import (Advisory, AdvisoryType, ConfirmedDetection, ManualObservation,
                     ReadinessStatus, SegmentScan, TrapCount, WeatherReading)


@dataclass
class SegmentStatus:
    segment: str
    readiness: Optional[float]
    status: ReadinessStatus
    open_bolls: int
    scanned: datetime


@dataclass
class FarmReport:
    farm: str
    generated: datetime
    segments: list[SegmentStatus]
    window: Optional[rules.WindowResult]
    findings: list[PestFinding]
    advisories: list[Advisory] = field(default_factory=list)


def _check_tz(now: datetime, scans: list[SegmentScan],
              forecast: list[tuple[datetime, float]]) -> None:
    """All datetimes must be either timezone-aware or naive LOCAL (IST) time.
    A mix cannot be compared safely, so it is refused with a clear message."""
    aware = now.tzinfo is not None
    for label, dt in [("scan", s.ts) for s in scans] + [("forecast", t) for t, _ in forecast]:
        if (dt.tzinfo is not None) != aware:
            raise ValueError(f"mixed naive and timezone-aware datetimes ({label} {dt.isoformat()} "
                             f"vs now {now.isoformat()}); use one kind everywhere")


def run_farm(farm: str, now: datetime, thresholds: dict, pests: dict,
             scans: Iterable[SegmentScan] = (),
             traps: Iterable[TrapCount] = (),
             manual: Iterable[ManualObservation] = (),
             confirmed: Iterable[ConfirmedDetection] = (),
             weather_now: Optional[WeatherReading] = None,
             rain_last_24h_mm: float = 0.0,
             forecast: Iterable[tuple[datetime, float]] = (),
             pest_window_days: int = 7) -> FarmReport:
    """Run every rule for one farm.

    Datetimes: pass all of them timezone-aware, or all naive in local (IST)
    time. Data dated after `now` is ignored, so past days can be replayed
    for experiments (QA bug 6).
    """
    forecast = list(forecast)
    scans = [s for s in scans if s.farm == farm]
    _check_tz(now, scans, forecast)
    scans = [s for s in scans if s.ts <= now]
    # Trap and scouting records carry Indian calendar dates, so 'today' is the
    # IST date even when now is in UTC (as in cloud functions).
    local_now = now.astimezone(rules.IST) if now.tzinfo else now
    today = local_now.date()
    latest = rules.latest_by_segment(scans)

    seg_status = []
    for k, s in sorted(latest.items()):
        r = rules.readiness(s.counts)
        seg_status.append(SegmentStatus(k, None if r is None else round(r, 4),
                                        rules.readiness_status(r, thresholds),
                                        s.counts["boll_open"], s.ts))
    hours = thresholds["rain_alert"]["window_hours"]

    window = (rules.picking_window(weather_now, now, rain_last_24h_mm, thresholds)
              if weather_now else None)

    advisories: list[Advisory] = []
    urgent = rules.rain_alert(farm, latest.values(), forecast, now, thresholds)
    if urgent:
        advisories.append(fill_text(urgent, hours=hours))
    else:
        routine = rules.pick_list(farm, latest.values(), now, thresholds)
        if routine:
            advisories.append(fill_text(routine, hours=hours))

    # Pest evidence: last `pest_window_days` days only.
    since = now - timedelta(days=pest_window_days)
    since_day = today - timedelta(days=pest_window_days)
    inputs = EtlInputs(
        scans=[s for s in scans if s.ts >= since],
        traps=[t for t in traps if t.farm == farm and since_day <= t.date <= today],
        manual=[m for m in manual if m.farm == farm and since_day <= m.date <= today],
        confirmed=[c for c in confirmed if c.farm == farm and since_day <= c.date <= today],
    )
    findings = evaluate(pests, inputs)
    blocked = rules.spray_blocked(latest.values(), thresholds)

    for f in findings:
        if not f.crossed:
            continue
        rule = pests[f.pest]
        if f.action == "ALERT_ONLY":
            typ = AdvisoryType.PEST_ALERT
        elif blocked:
            typ = AdvisoryType.SPRAY_BLOCKED
        elif f.action == "SPOT_TREAT":
            typ = AdvisoryType.SPOT_TREAT
        else:
            typ = AdvisoryType.PEST_ETL
        adv = Advisory(farm=farm, type=typ, created=now, segments=f.segments,
                       pest=f.pest, reason=f"{f.pest}: {f.detail}")
        advisories.append(fill_text(adv, rule.get("name_en", f.pest),
                                    rule.get("name_ta", ""), hours=hours))

    return FarmReport(farm, now, seg_status, window, findings, advisories)
