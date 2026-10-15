"""Shared data model for BollBot Scout.

These dataclasses are the single definition of every record that moves
between the cart (edge), the cloud rules engine and the app. Their
to_dict()/from_dict() forms are exactly the JSON documents in Section 11
of the specification, so every layer serialises them the same way.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from datetime import datetime, date
from enum import Enum
from typing import Optional

# The 8 detector classes, in model index order (Section 6). Never reorder:
# index i here must equal class id i in the YOLO data.yaml.
CLASSES: tuple[str, ...] = (
    "boll_closed",
    "boll_cracking",
    "boll_open",
    "boll_defective",
    "flower",
    "rosette_flower",
    "boll_bored",
    "mealybug_colony",
)
BOLL_STAGE_CLASSES = ("boll_closed", "boll_cracking", "boll_open")


class ReadinessStatus(str, Enum):
    READY = "READY"
    BUILDING = "BUILDING"
    NOT_READY = "NOT_READY"
    NO_DATA = "NO_DATA"


class WindowStatus(str, Enum):
    SAFE = "SAFE"
    WAIT = "WAIT"


class AdvisoryType(str, Enum):
    PICK_NOW = "PICK_NOW"          # rain coming, ready cotton on the plant
    PICK_LIST = "PICK_LIST"        # routine ranked list of ready segments
    PEST_ETL = "PEST_ETL"          # an ETL is crossed (advisory)
    SPOT_TREAT = "SPOT_TREAT"      # mealybug spot treatment justified
    PEST_ALERT = "PEST_ALERT"      # alert only, no chemical action
    SPRAY_BLOCKED = "SPRAY_BLOCKED"  # ETL crossed but picking is close (PHI)


class PestAction(str, Enum):
    ADVISORY = "ADVISORY"
    SPOT_TREAT = "SPOT_TREAT"
    ALERT_ONLY = "ALERT_ONLY"


def _parse_dt(value: str | datetime) -> datetime:
    if isinstance(value, datetime):
        return value
    # Python 3.10 fromisoformat() does not accept a trailing 'Z', which
    # Firestore and JavaScript produce (QA bug 13).
    return datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)


def _parse_date(value: str | date) -> date:
    return value if isinstance(value, date) else date.fromisoformat(value)


def segment_id(row: int, segment: int) -> str:
    """Human-readable segment key, e.g. R012-S04."""
    return f"R{row:03d}-S{segment:02d}"


@dataclass
class WeatherReading:
    t_c: float
    rh: float
    dewpoint_c: Optional[float] = None

    def to_dict(self) -> dict:
        return {k: v for k, v in asdict(self).items() if v is not None}

    @classmethod
    def from_dict(cls, d: dict) -> "WeatherReading":
        return cls(t_c=float(d["t_c"]), rh=float(d["rh"]),
                   dewpoint_c=d.get("dewpoint_c"))


@dataclass
class SegmentScan:
    """One pass of the cart (or one phone-capture session) over a row segment."""
    farm: str
    row: int
    segment: int
    ts: datetime
    counts: dict[str, int]
    model: str
    weather: Optional[WeatherReading] = None
    evidence: list[str] = field(default_factory=list)
    source: str = "cart"  # "cart" | "phone"

    def __post_init__(self) -> None:
        unknown = set(self.counts) - set(CLASSES)
        if unknown:
            raise ValueError(f"unknown classes in counts: {sorted(unknown)}")
        if any(v < 0 for v in self.counts.values()):
            raise ValueError("counts must be non-negative")
        # Fill missing classes with 0 so every consumer sees all 8 keys.
        self.counts = {c: int(self.counts.get(c, 0)) for c in CLASSES}

    @property
    def segment_key(self) -> str:
        return segment_id(self.row, self.segment)

    @property
    def scan_id(self) -> str:
        return f"{self.farm}-{self.segment_key}-{self.ts.strftime('%Y%m%dT%H%M')}"

    def to_dict(self) -> dict:
        from .rules import readiness  # local import avoids a cycle
        d = {
            "scan_id": self.scan_id,
            "farm": self.farm,
            "row": self.row,
            "segment": self.segment,
            "ts": self.ts.isoformat(),
            "counts": dict(self.counts),
            "readiness": None if (r := readiness(self.counts)) is None else round(r, 4),
            "model": self.model,
            "evidence": list(self.evidence),
            "source": self.source,
        }
        if self.weather:
            d["weather"] = self.weather.to_dict()
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "SegmentScan":
        return cls(
            farm=d["farm"], row=int(d["row"]), segment=int(d["segment"]),
            ts=_parse_dt(d["ts"]), counts=dict(d["counts"]), model=d["model"],
            weather=WeatherReading.from_dict(d["weather"]) if d.get("weather") else None,
            evidence=list(d.get("evidence", [])), source=d.get("source", "cart"),
        )


@dataclass
class TrapCount:
    farm: str
    trap: str          # e.g. "PBW-2"; prefix identifies the pest
    date: date         # the night the count covers
    moths: int
    photo: Optional[str] = None

    def to_dict(self) -> dict:
        d = {"farm": self.farm, "trap": self.trap,
             "date": self.date.isoformat(), "moths": self.moths}
        if self.photo:
            d["photo"] = self.photo
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "TrapCount":
        return cls(farm=d["farm"], trap=d["trap"], date=_parse_date(d["date"]),
                   moths=int(d["moths"]), photo=d.get("photo"))


@dataclass
class ManualObservation:
    """Operator scouting record, e.g. whitefly adults counted on 20 leaves."""
    farm: str
    date: date
    observation: str   # key referenced by etl.yaml, e.g. "whitefly_adults_per_leaf"
    count: int         # total counted (insects, infested plants, ...)
    units: int         # leaves or plants examined

    def to_dict(self) -> dict:
        return {"farm": self.farm, "date": self.date.isoformat(),
                "observation": self.observation, "count": self.count,
                "units": self.units}

    @classmethod
    def from_dict(cls, d: dict) -> "ManualObservation":
        return cls(farm=d["farm"], date=_parse_date(d["date"]),
                   observation=d["observation"], count=int(d["count"]),
                   units=int(d["units"]))


@dataclass
class ConfirmedDetection:
    """A camera detection a human confirmed in the app (needed for SPOT_TREAT)."""
    farm: str
    row: int
    segment: int
    cls: str
    date: date

    def to_dict(self) -> dict:
        return {"farm": self.farm, "row": self.row, "segment": self.segment,
                "class": self.cls, "date": self.date.isoformat()}


@dataclass
class Advisory:
    farm: str
    type: AdvisoryType
    reason: str
    created: datetime
    segments: list[str] = field(default_factory=list)
    pest: Optional[str] = None
    text_en: str = ""
    text_ta: str = ""

    def to_dict(self) -> dict:
        d = {"farm": self.farm, "type": self.type.value, "reason": self.reason,
             "segments": list(self.segments), "text_en": self.text_en,
             "text_ta": self.text_ta, "created": self.created.isoformat()}
        if self.pest:
            d["pest"] = self.pest
        return d
