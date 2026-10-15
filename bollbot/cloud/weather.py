"""Rain forecast and recent rain from Open-Meteo (free, no API key).

API: https://open-meteo.com/en/docs. One request per farm per hour returns
hourly rain probability, rain amount, temperature and humidity for the past
day and the next 3 days, in Indian local time.
"""
from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Optional

from bollbot.core.models import WeatherReading
from bollbot.core.rules import dew_point_c

API = "https://api.open-meteo.com/v1/forecast"
HOURLY = ("precipitation_probability", "precipitation", "temperature_2m", "relative_humidity_2m")


@dataclass
class FarmWeather:
    fetched: datetime
    forecast: list[tuple[datetime, float]] = field(default_factory=list)   # (hour, rain probability %)
    rain_last_24h_mm: float = 0.0
    now_reading: Optional[WeatherReading] = None                          # model value for this hour

    def to_doc(self) -> dict:
        return {"fetched": self.fetched.isoformat(),
                "forecast": [{"t": t.isoformat(), "p": p} for t, p in self.forecast],
                "rain_last_24h_mm": self.rain_last_24h_mm,
                "now": self.now_reading.to_dict() if self.now_reading else None}

    @classmethod
    def from_doc(cls, d: dict) -> "FarmWeather":
        return cls(fetched=datetime.fromisoformat(d["fetched"]),
                   forecast=[(datetime.fromisoformat(x["t"]), float(x["p"])) for x in d.get("forecast", [])],
                   rain_last_24h_mm=float(d.get("rain_last_24h_mm", 0.0)),
                   now_reading=WeatherReading.from_dict(d["now"]) if d.get("now") else None)


def request_url(lat: float, lon: float) -> str:
    q = {"latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}", "hourly": ",".join(HOURLY),
         "past_days": 1, "forecast_days": 3, "timezone": "Asia/Kolkata"}
    return f"{API}?{urllib.parse.urlencode(q)}"


def parse(resp: dict, now: datetime) -> FarmWeather:
    """Parse an Open-Meteo response. `now` must be timezone-aware."""
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    h = resp.get("hourly") or {}
    times = h.get("time") or []
    for k in HOURLY:
        if len(h.get(k) or []) != len(times):
            raise ValueError(f"Open-Meteo response: '{k}' length differs from 'time'")
    tz = timezone(timedelta(seconds=int(resp.get("utc_offset_seconds", 19800))))
    # Times are local ("2027-01-18T10:00") when a timezone is requested; keep an
    # explicit offset if Open-Meteo ever includes one.
    hours = [(lambda d: d if d.tzinfo else d.replace(tzinfo=tz))(datetime.fromisoformat(t))
             for t in times]

    forecast, rain24, current = [], 0.0, None
    for i, t in enumerate(hours):
        prob, mm = h["precipitation_probability"][i], h["precipitation"][i]
        if t >= now - timedelta(hours=1) and prob is not None:
            forecast.append((t, float(prob)))
        if now - timedelta(hours=24) < t <= now and mm is not None:
            rain24 += float(mm)
        if t <= now < t + timedelta(hours=1):
            temp, rh = h["temperature_2m"][i], h["relative_humidity_2m"][i]
            if temp is not None and rh:
                current = WeatherReading(float(temp), float(rh), dew_point_c(float(temp), float(rh)))
    return FarmWeather(now, forecast, round(rain24, 2), current)


def fetch(lat: float, lon: float, now: datetime, timeout_s: float = 15.0) -> FarmWeather:
    with urllib.request.urlopen(request_url(lat, lon), timeout=timeout_s) as r:
        return parse(json.loads(r.read().decode("utf-8")), now)
