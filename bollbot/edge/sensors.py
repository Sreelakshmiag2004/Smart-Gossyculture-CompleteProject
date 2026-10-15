"""On-cart weather sensor (BME280) for the picking-window rule (spec Section 8).

BME280 on the Pi's I2C bus (SDA = GPIO2, SCL = GPIO3, 3.3 V). Enable I2C
with `sudo raspi-config` -> Interface Options -> I2C, then check the address
with `i2cdetect -y 1` (0x76 or 0x77).
Requires: pip install smbus2 RPi.bme280
"""
from __future__ import annotations

from typing import Optional, Protocol

from bollbot.core.models import WeatherReading
from bollbot.core.rules import dew_point_c


class WeatherSource(Protocol):
    def read(self) -> Optional[WeatherReading]:
        """Return a reading, or None if the sensor is unavailable."""


class NoWeather:
    def read(self) -> Optional[WeatherReading]:
        return None


class FixedWeather:
    """For tests and video replays."""

    def __init__(self, t_c: float, rh: float):
        self._r = WeatherReading(t_c, rh, dew_point_c(t_c, rh))

    def read(self) -> Optional[WeatherReading]:
        return self._r


class BME280Source:
    def __init__(self, bus: int = 1, address: int = 0x76):
        import bme280          # package: RPi.bme280
        import smbus2
        self._bme280 = bme280
        self._bus = smbus2.SMBus(bus)
        self._addr = address
        self._cal = bme280.load_calibration_params(self._bus, address)
        self.errors = 0

    def read(self) -> Optional[WeatherReading]:
        try:
            s = self._bme280.sample(self._bus, self._addr, self._cal)
            t, rh = round(float(s.temperature), 2), round(float(s.humidity), 1)
            if not (-10 <= t <= 60) or not (0 < rh <= 105):
                raise ValueError(f"implausible reading t={t} rh={rh}")
            return WeatherReading(t, rh, dew_point_c(t, rh))
        except Exception:  # noqa: BLE001 - a bad reading must not stop scanning
            self.errors += 1
            return None


def make_weather(cfg: dict) -> WeatherSource:
    """A missing or unwired sensor must not stop scanning: counting does not
    need weather, so fall back to NoWeather with a warning."""
    import logging
    w = cfg.get("weather", {})
    if w.get("kind") == "bme280":
        try:
            return BME280Source(int(w.get("i2c_bus", 1)), int(w.get("address", 0x76)))
        except (ImportError, OSError) as e:
            logging.getLogger(__name__).warning(
                "BME280 unavailable (%s): scanning without weather; "
                "install smbus2 + RPi.bme280 and check i2cdetect", e)
    return NoWeather()
