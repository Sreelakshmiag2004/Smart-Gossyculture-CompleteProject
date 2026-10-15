from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import Field

from gossy.auth.schemas import ApiModel, Phone
from gossy.farmrules.core.models import CLASSES
from gossy.ids import ULID_PATTERN

AdvisoryTypeName = Literal["PICK_NOW", "PICK_LIST", "PEST_ETL", "SPOT_TREAT", "PEST_ALERT", "SPRAY_BLOCKED"]
ClassName = Literal[CLASSES]  # the 8 detector classes, in model order
RowNo = Annotated[int, Field(ge=1, le=10_000)]


# ----------------------------------------------------------------------------- members
class MemberAdd(ApiModel):
    phone: Phone


class FarmMember(ApiModel):
    user_id: uuid.UUID
    phone: str
    display_name: str | None
    role: Literal["operator"] = Field(description="Operators enter trap, scouting and confirmation data and read the farm's advice")
    added_at: datetime


# ----------------------------------------------------------------------------- data entry
class TrapCountIn(ApiModel):
    trap: Annotated[str, Field(pattern=r"^[A-Za-z]{2,8}-[0-9A-Za-z]{1,8}$", description="Trap id; the prefix names the pest, e.g. PBW-1", examples=["PBW-1"])]
    night: date = Field(description="Night the count covers (Indian date)")
    moths: Annotated[int, Field(ge=0, le=10_000)]


class TrapCount(ApiModel):
    id: uuid.UUID
    trap: str
    night: date
    moths: int
    recorded_at: datetime
    recorded_by: uuid.UUID


class ObservationIn(ApiModel):
    observed_on: date = Field(description="Day of the field sample (Indian date)")
    observation: Annotated[str, Field(min_length=1, max_length=64, description="Key from GET /api/v1/farm-rules/catalog, e.g. aphid_infested_plants")]
    count: Annotated[int, Field(ge=0, le=100_000, description="Insects, infested plants, ... counted")]
    units: Annotated[int, Field(ge=1, le=10_000, description="Leaves or plants examined")]
    row: RowNo | None = None
    segment: RowNo | None = None


class Observation(ApiModel):
    id: uuid.UUID
    observed_on: date
    observation: str
    pest: str
    count: int
    units: int
    row: int | None
    segment: int | None
    recorded_at: datetime
    recorded_by: uuid.UUID


class ConfirmationIn(ApiModel):
    observed_on: date
    row: RowNo
    segment: RowNo
    class_name: ClassName
    verdict: Literal["confirmed", "rejected"]
    source_msg_id: Annotated[str, Field(pattern=ULID_PATTERN, description="msgId of the scan or detection that was checked")] | None = None


class Confirmation(ApiModel):
    id: uuid.UUID
    observed_on: date
    row: int
    segment: int
    class_name: str
    verdict: str
    source_msg_id: str | None
    recorded_at: datetime
    recorded_by: uuid.UUID


# ----------------------------------------------------------------------------- output of the rules
class Advisory(ApiModel):
    id: uuid.UUID
    type: AdvisoryTypeName
    pest: str | None
    segments: list[str] = Field(description="Row segments, e.g. R003-S02, most urgent first")
    reason: str = Field(description="Why the rule fired (for the operator; not translated)")
    text_en: str
    text_ta: str = Field(description="Tamil text. Must be reviewed by a native speaker before farmer trials (E9).")
    active: bool
    created_at: datetime
    updated_at: datetime
    resolved_at: datetime | None


class SegmentStatus(ApiModel):
    key: str = Field(examples=["R003-S02"])
    row: int
    segment: int
    readiness: float | None = Field(description="R = open / (closed + cracking + open) from the latest scan; null if no bolls were seen")
    status: Literal["READY", "BUILDING", "NOT_READY", "NO_DATA"]
    open_bolls: int
    scanned_at: datetime


class PickingWindow(ApiModel):
    status: Literal["SAFE", "WAIT"]
    dewpoint_c: float
    dewpoint_depression_c: float
    reasons: list[str] = Field(description="Why it is not safe yet (empty when SAFE)")


class WeatherNow(ApiModel):
    air_temp_c: float
    air_rh_pct: float
    dewpoint_c: float | None
    source: Literal["cart", "forecast"] = Field(description="The cart's own sensor when it read in the last 2 h, else the forecast model")


class PestStatus(ApiModel):
    pest: str
    crossed: bool
    insufficient: bool = Field(description="Too little evidence to decide: scout more")
    value: float | None
    threshold: float
    action: Literal["ADVISORY", "SPOT_TREAT", "ALERT_ONLY"]
    detail: str
    segments: list[str]


class FarmStatus(ApiModel):
    farm_id: uuid.UUID
    computed_at: datetime | None = Field(description="Null until the rules have run for this farm")
    segments: list[SegmentStatus] = []
    window: PickingWindow | None = Field(default=None, description="Null without a weather reading (no recent cart reading and no forecast)")
    weather_now: WeatherNow | None = None
    forecast_fetched_at: datetime | None = None
    rain_last_24h_mm: float | None = None
    rain_max_prob_48h_pct: float | None = None
    pests: list[PestStatus] = []


class PestRule(ApiModel):
    pest: str
    name_en: str
    name_ta: str
    rule_type: Literal["consecutive_nights", "camera_ratio", "mean_per_unit", "percent_units", "presence"]
    evidence: str = Field(description="trap | camera | manual | camera_confirmed")
    observation: str | None = Field(description="Scouting key to send in POST .../observations (manual rules)")
    trap_prefix: str | None
    threshold: float
    comparison: Literal[">", ">="]
    min_units: int | None
    nights: int | None
    action: Literal["ADVISORY", "SPOT_TREAT", "ALERT_ONLY"]
