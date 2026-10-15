"""Harvest-readiness, picking-window and rain-alert rules (spec Section 8).

All functions are pure: they take data + a thresholds dict and return
results. No I/O, no clocks; the caller passes `now`. This keeps them
testable and lets the cart, the cloud and the experiments share them.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

from .models import (Advisory, AdvisoryType, ReadinessStatus, SegmentScan,
                     WeatherReading, WindowStatus)

# Magnus formula constants (Alduchov & Eskridge coefficients, valid ~ -40..50 C)
_MAGNUS_A = 17.625
_MAGNUS_B = 243.04

# India Standard Time. A fixed offset (India has no daylight saving) avoids
# needing the tzdata package on Windows. The picking window's earliest_hour
# is a LOCAL-time rule, so aware datetimes are converted to IST (QA bug 2).
IST = timezone(timedelta(hours=5, minutes=30))


# ---------------------------------------------------------------- readiness
def readiness(counts: dict[str, int]) -> Optional[float]:
    """R = open / (closed + cracking + open). None when no bolls were seen.

    Returned UNROUNDED: thresholds compare the exact ratio. Round only for
    display (QA bug 12)."""
    closed = counts.get("boll_closed", 0)
    cracking = counts.get("boll_cracking", 0)
    opened = counts.get("boll_open", 0)
    total = closed + cracking + opened
    if total == 0:
        return None
    return opened / total


def readiness_status(r: Optional[float], cfg: dict) -> ReadinessStatus:
    if r is None:
        return ReadinessStatus.NO_DATA
    t = cfg["readiness"]
    if r >= t["ready_min"]:
        return ReadinessStatus.READY
    if r >= t["building_min"]:
        return ReadinessStatus.BUILDING
    return ReadinessStatus.NOT_READY


def latest_by_segment(scans: Iterable[SegmentScan]) -> dict[str, SegmentScan]:
    """Keep only the most recent scan of each row segment."""
    latest: dict[str, SegmentScan] = {}
    for s in scans:
        cur = latest.get(s.segment_key)
        if cur is None or s.ts > cur.ts:
            latest[s.segment_key] = s
    return latest


def rank_segments(scans: Iterable[SegmentScan], min_r: float) -> list[SegmentScan]:
    """Latest scans with R >= min_r, most open bolls first (ties: higher R)."""
    picked = [s for s in latest_by_segment(scans).values()
              if (readiness(s.counts) or 0) >= min_r]
    return sorted(picked, key=lambda s: (-s.counts["boll_open"],
                                         -(readiness(s.counts) or 0),
                                         s.segment_key))


# ---------------------------------------------------------- picking window
def dew_point_c(t_c: float, rh_pct: float) -> float:
    """Dew point (deg C) from air temperature and relative humidity (Magnus)."""
    # Capacitive sensors (BME280) read slightly above 100 % at saturation;
    # treat up to 105 % as 100 % rather than failing the whole run (QA bug 5).
    if not 0 < rh_pct <= 105:
        raise ValueError(f"relative humidity must be in (0, 105], got {rh_pct}")
    rh_pct = min(rh_pct, 100.0)
    gamma = math.log(rh_pct / 100.0) + _MAGNUS_A * t_c / (_MAGNUS_B + t_c)
    return round(_MAGNUS_B * gamma / (_MAGNUS_A - gamma), 2)


@dataclass
class WindowResult:
    status: WindowStatus
    dewpoint_c: float
    dewpoint_depression_c: float
    failed: list[str] = field(default_factory=list)  # human-readable reasons


def picking_window(weather: WeatherReading, now: datetime,
                   rain_last_24h_mm: float, cfg: dict) -> WindowResult:
    """SAFE only when all four conditions in thresholds.yaml hold.

    Each limit is the largest (or smallest) ALLOWED value: RH 75 % and rain
    2.0 mm are still allowed; 75.1 % and 2.1 mm are not.
    """
    t = cfg["picking_window"]
    if now.tzinfo is not None:
        now = now.astimezone(IST)
    td = weather.dewpoint_c if weather.dewpoint_c is not None \
        else dew_point_c(weather.t_c, weather.rh)
    depression = round(weather.t_c - td, 2)
    failed = []
    if now.hour < t["earliest_hour"]:
        failed.append(f"before {t['earliest_hour']:02d}:00 (dew may remain)")
    if depression < t["min_dewpoint_depression_c"]:
        failed.append(f"dew-point depression {depression} C < "
                      f"{t['min_dewpoint_depression_c']} C")
    if weather.rh > t["max_rh_pct"]:
        failed.append(f"RH {weather.rh}% > {t['max_rh_pct']}%")
    if rain_last_24h_mm > t["max_rain_last_24h_mm"]:
        failed.append(f"rain {rain_last_24h_mm} mm in last 24 h")
    return WindowResult(WindowStatus.WAIT if failed else WindowStatus.SAFE,
                        td, depression, failed)


# --------------------------------------------------------------- advisories
def rain_alert(farm: str, scans: Iterable[SegmentScan],
               forecast: Iterable[tuple[datetime, float]],
               now: datetime, cfg: dict) -> Optional[Advisory]:
    """PICK_NOW when rain is likely soon and open cotton is on the plant.

    forecast: (time, precipitation probability %) pairs, e.g. hourly
    values from Open-Meteo.
    """
    t = cfg["rain_alert"]
    horizon = now + timedelta(hours=t["window_hours"])
    probs = [p for ts, p in forecast if now <= ts <= horizon]
    if not probs:
        return None
    max_prob = max(probs)
    if max_prob < t["min_rain_prob_pct"]:
        return None
    ranked = rank_segments(scans, t["min_segment_readiness"])
    if not ranked:
        return None
    segs = [s.segment_key for s in ranked]
    return Advisory(
        farm=farm, type=AdvisoryType.PICK_NOW, created=now, segments=segs,
        reason=(f"rain_prob_{t['window_hours']}h={max_prob:.0f}%, "
                f"{len(segs)} segments R>={t['min_segment_readiness']}"),
    )


def pick_list(farm: str, scans: Iterable[SegmentScan], now: datetime,
              cfg: dict) -> Optional[Advisory]:
    """Routine ranked list of READY segments (no rain urgency)."""
    ranked = rank_segments(scans, cfg["readiness"]["ready_min"])
    if not ranked:
        return None
    return Advisory(farm=farm, type=AdvisoryType.PICK_LIST, created=now,
                    segments=[s.segment_key for s in ranked],
                    reason=f"{len(ranked)} segments READY")


def spray_blocked(scans: Iterable[SegmentScan], cfg: dict) -> bool:
    """True if any segment is close enough to picking that spraying must wait."""
    limit = cfg["spray_block"]["min_segment_readiness"]
    return any((readiness(s.counts) or 0) >= limit
               for s in latest_by_segment(scans).values())


def moisture_class(moisture_pct: float, cfg: dict) -> str:
    """Oven-dry moisture (wet basis %) -> SAFE / DRY_AND_PICK / TOO_WET.
    Used by experiment E4 to score the picking-window rule."""
    m = cfg.get("moisture_classes", {"safe_max_pct": 8.0, "dry_and_pick_max_pct": 12.0})
    if moisture_pct <= m["safe_max_pct"]:
        return "SAFE"
    if moisture_pct <= m["dry_and_pick_max_pct"]:
        return "DRY_AND_PICK"
    return "TOO_WET"


def wet_basis_moisture(w_wet_g: float, w_dry_g: float) -> float:
    """Gravimetric moisture, wet basis: (W_wet - W_dry) / W_wet * 100."""
    if w_wet_g <= 0 or w_dry_g < 0 or w_dry_g > w_wet_g:
        raise ValueError("need w_wet > 0 and 0 <= w_dry <= w_wet")
    return round((w_wet_g - w_dry_g) / w_wet_g * 100, 2)
