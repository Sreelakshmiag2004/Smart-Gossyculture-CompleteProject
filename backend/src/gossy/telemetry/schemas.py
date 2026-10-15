from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import Field

from gossy.auth.schemas import ApiModel

EventType = Literal["pest", "spray", "harvest", "scan", "pick"]


class TelemetryPoint(ApiModel):
    time: datetime = Field(description="Device timestamp")
    received_at: datetime = Field(description="When the backend received the reading (the receivedAt of the live event for the same msgId). Freshness is measured from this, not from the device timestamp.")
    msg_id: str
    battery_pct: float | None = Field(description="Omitted by devices without a battery monitor")
    moisture_rh_pct: float | None = Field(description="Relative humidity reported by the moisture sensor. A reading only - no harvest-readiness verdict is derived (U-1 unresolved).")
    air_temp_c: float | None
    bolls_harvested_total: int | None
    solar_active: bool | None
    air_rh_pct: float | None = Field(default=None, description="Air relative humidity (weather), used by the picking-window rule; not boll moisture")
    dewpoint_c: float | None = None


class DeviceEvent(ApiModel):
    time: datetime = Field(description="Device timestamp")
    msg_id: str
    device_id: str
    type: EventType
    data: dict = Field(description="Validated event payload as defined by the MQTT contract (camelCase)")


class Detection(ApiModel):
    id: str = Field(description="Source message id (ULID)")
    device_id: str
    detected_at: datetime
    label: str = Field(description="Class name reported by the upstream detector, e.g. bollworm, leaf_curl_virus")
    confidence: float = Field(ge=0, le=1, description="Confidence reported by the upstream detector")
    bbox: list[float] | None = Field(description="Normalised [x, y, width, height]")
    source: Literal["upstream_device_detector"] = Field(
        default="upstream_device_detector",
        description="Detections are produced on the device. The backend performs no inference and makes no accuracy claim.",
    )
