"""Typed MQTT payloads (JSON, camelCase on the wire).

Every data field is traceable to a requirement document or to Phase 0; see docs/mqtt-contract.md.
Validation is strict (no type coercion). The envelope rejects unknown keys; ``data`` ignores
unknown keys so that devices can add fields in a backwards-compatible minor revision.
"""

from __future__ import annotations

from typing import Annotated, Generic, Literal, TypeVar

from pydantic import AfterValidator, AwareDatetime, BaseModel, ConfigDict, Field, model_validator
from pydantic.alias_generators import to_camel

from gossy.contracts.topics import DEVICE_ID_PATTERN, RESERVED_SERVICE_PREFIX, MessageKind
from gossy.ids import ULID_PATTERN

Percent = Annotated[float, Field(ge=0, le=100)]
UnitInterval = Annotated[float, Field(ge=0, le=1)]
Ulid = Annotated[str, Field(pattern=ULID_PATTERN)]


def _not_service_account(value: str) -> str:
    if value.startswith(RESERVED_SERVICE_PREFIX):
        raise ValueError("deviceId uses the reserved service-account prefix")
    return value


DeviceId = Annotated[str, Field(pattern=DEVICE_ID_PATTERN), AfterValidator(_not_service_account)]


class _Data(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, strict=True, extra="ignore", frozen=True)


class TelemetryData(_Data):
    # Paper §III.B: "battery levels" are logged and shown in the app. Optional since Phase II:
    # a reading the device cannot make is omitted, never faked (see "Reporting interval"), and
    # a cart without a battery monitor still reports its other readings.
    battery_pct: Percent | None = None
    # Paper §V.A: moisture module (DHT11/DHT22) reports %RH. Agronomic meaning is U-1 (unresolved);
    # the backend stores the reading only and makes no harvesting decision.
    moisture_rh_pct: Percent | None = None
    # PPT module 5: temperature sensor. Range = DHT22 operating range.
    air_temp_c: Annotated[float, Field(ge=-40, le=85)] | None = None
    # Paper §III.B: "harvested boll counts".
    bolls_harvested_total: Annotated[int, Field(ge=0)] | None = None
    # PPT module 6 (power monitoring) and existing dashboard "Solar Active" indicator.
    solar_active: bool | None = None
    # Phase II: AIR relative humidity and dew point from the cart's BME280. This is weather for
    # the picking-window rule, NOT boll moisture (resolves U-1: moisture_rh_pct is not used for
    # harvesting decisions).
    air_rh_pct: Percent | None = None
    dewpoint_c: Annotated[float, Field(ge=-40, le=60)] | None = None
    # Phase II cart health: camera frames per second and records waiting in the cart's outbox.
    # Kept in the ingestion ledger (ingested_messages.data); no telemetry column.
    fps: Annotated[float, Field(ge=0, le=1000)] | None = None
    outbox_pending: Annotated[int, Field(ge=0)] | None = None

    @model_validator(mode="after")
    def _at_least_one_reading(self) -> "TelemetryData":
        if not self.model_dump(exclude_none=True):
            raise ValueError("telemetry must contain at least one reading")
        return self


class PestEventData(_Data):
    # Paper §III.B: detections carry class name, confidence and bounding box.
    label: Annotated[str, Field(min_length=1, max_length=64, pattern=r"^[a-z0-9][a-z0-9_-]*$")]
    confidence: UnitInterval
    # Normalised [x, y, width, height] in the camera frame.
    bbox: tuple[UnitInterval, UnitInterval, UnitInterval, UnitInterval] | None = None


class SprayEventData(_Data):
    # PPT module 4: short controlled bursts; the event is logged. The upper bound is a sanity
    # limit for validation only — burst limits are enforced by device firmware, not the backend.
    # 0 is allowed only for a spray that did not run (completed = false: refused or aborted at once).
    duration_ms: Annotated[int, Field(ge=0, le=60_000)]
    # Links the spray to the pest detection that triggered it (PPT module 4 "log the event").
    related_msg_id: Ulid | None = None
    # Phase II (experiment E7): dose and outcome of the spot spray.
    completed: bool | None = None
    reason: Annotated[str, Field(max_length=64)] | None = None        # firmware block reason, e.g. deadman_released
    ml_requested: Annotated[float, Field(ge=0, le=10_000)] | None = None
    ml_delivered: Annotated[float, Field(ge=0, le=10_000)] | None = None
    purpose: Annotated[str, Field(max_length=32)] | None = None       # e.g. mealybug_spot, calibration
    row: Annotated[int, Field(ge=1, le=10_000)] | None = None
    segment: Annotated[int, Field(ge=1, le=10_000)] | None = None

    @model_validator(mode="after")
    def _zero_only_if_not_run(self) -> "SprayEventData":
        if self.duration_ms == 0 and self.completed is not False:
            raise ValueError("durationMs 0 is only valid with completed = false")
        return self


class HarvestEventData(_Data):
    # PPT: bolls classified Mature / Immature / Partial.
    maturity: Literal["mature", "immature", "partial"]
    picked: bool
    moisture_rh_pct: Percent | None = None


Count = Annotated[int, Field(ge=0, le=100_000)]


class ScanCounts(_Data):
    """Tracked objects counted once per pass, per detector class (Phase II spec Section 6)."""
    boll_closed: Count = 0
    boll_cracking: Count = 0
    boll_open: Count = 0
    boll_defective: Count = 0
    flower: Count = 0
    rosette_flower: Count = 0
    boll_bored: Count = 0
    mealybug_colony: Count = 0


class ScanEventData(_Data):
    # Phase II: the cart closes a row segment (between two row markers) and reports its counts.
    # The farm comes from the device registry (devices.farm_id), never from the device.
    row: Annotated[int, Field(ge=1, le=10_000)]
    segment: Annotated[int, Field(ge=1, le=10_000)]
    counts: ScanCounts
    started_at: AwareDatetime
    frames: Annotated[int, Field(ge=0, le=10_000_000)]
    model: Annotated[str, Field(min_length=1, max_length=64)]
    # Weather at the segment, from the cart's BME280 (air, not boll moisture).
    air_temp_c: Annotated[float, Field(ge=-40, le=85)] | None = None
    air_rh_pct: Percent | None = None
    dewpoint_c: Annotated[float, Field(ge=-40, le=60)] | None = None


class PickEventData(_Data):
    # Phase II experiment E10: one robotic pick attempt, including failures.
    attempt_id: Annotated[str, Field(min_length=1, max_length=32, pattern=r"^[a-z0-9-]+$")]
    result: Literal["completed", "unreachable", "aborted"]
    reason: Annotated[str, Field(max_length=256)] | None = None
    row: Annotated[int, Field(ge=1, le=10_000)] | None = None
    segment: Annotated[int, Field(ge=1, le=10_000)] | None = None
    track_id: Annotated[int, Field(ge=0)] | None = None
    confidence: UnitInterval | None = None
    pitch_deg: Annotated[float, Field(ge=-90, le=90)] | None = None
    cycle_s: Annotated[float, Field(ge=0, le=600)] | None = None
    # Scored by the operator after inspecting the boll.
    outcome: Literal["picked", "partial", "missed", "damaged"] | None = None
    lint_left_g: Annotated[float, Field(ge=0, le=1000)] | None = None
    trash_g: Annotated[float, Field(ge=0, le=1000)] | None = None


class StatusData(_Data):
    # Phase 0: retained status; the broker publishes "offline" as the device's Last Will.
    state: Literal["online", "offline"]


DataT = TypeVar("DataT", bound=_Data)


class Envelope(BaseModel, Generic[DataT]):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, strict=True, extra="forbid", frozen=True)

    schema_id: str = Field(alias="schema", min_length=1, max_length=64)
    msg_id: Ulid
    device_id: DeviceId
    seq: Annotated[int, Field(ge=0, le=2**63 - 1)]
    ts: AwareDatetime
    data: DataT


DATA_MODELS: dict[MessageKind, type[_Data]] = {
    MessageKind.TELEMETRY: TelemetryData,
    MessageKind.PEST: PestEventData,
    MessageKind.SPRAY: SprayEventData,
    MessageKind.HARVEST: HarvestEventData,
    MessageKind.SCAN: ScanEventData,
    MessageKind.PICK: PickEventData,
    MessageKind.STATUS: StatusData,
}

SCHEMA_IDS: dict[MessageKind, str] = {
    MessageKind.TELEMETRY: "bollbot.telemetry/1",
    MessageKind.PEST: "bollbot.event.pest/1",
    MessageKind.SPRAY: "bollbot.event.spray/1",
    MessageKind.HARVEST: "bollbot.event.harvest/1",
    MessageKind.SCAN: "bollbot.event.scan/1",
    MessageKind.PICK: "bollbot.event.pick/1",
    MessageKind.STATUS: "bollbot.status/1",
}

ENVELOPE_MODELS: dict[MessageKind, type[Envelope]] = {kind: Envelope[model] for kind, model in DATA_MODELS.items()}
