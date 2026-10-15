"""Pure message construction for a simulated device (no I/O; unit-testable)."""

from __future__ import annotations

import json
import random
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from gossy.contracts.messages import SCHEMA_IDS
from gossy.contracts.topics import MessageKind, topic_for
from gossy.ids import new_ulid

SIM_PREFIX = "sim-"
# Pest classes named in the paper (§V.C): bollworm and leaf curl virus.
SIM_PEST_LABELS = ("bollworm", "leaf_curl_virus")


@dataclass(frozen=True)
class OutgoingMessage:
    topic: str
    payload: bytes
    msg_id: str
    kind: MessageKind
    retain: bool = False


class SimulatedDevice:
    def __init__(
        self,
        device_id: str,
        *,
        rng: random.Random | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
        start_seq: int = 0,
    ):
        if not device_id.startswith(SIM_PREFIX):
            raise ValueError(f"simulator device ids must start with {SIM_PREFIX!r} (got {device_id!r})")
        topic_for(device_id, MessageKind.TELEMETRY)  # validates the id format
        self.device_id = device_id
        self._rng = rng or random.Random()
        self._clock = clock
        self._seq = start_seq
        # Synthetic state; values are illustrative, not agronomic.
        self._battery = 100.0
        self._bolls_total = 0
        self._pick_n = 0

    def _message(self, kind: MessageKind, data: dict, *, retain: bool = False) -> OutgoingMessage:
        msg_id = new_ulid()
        envelope = {
            "schema": SCHEMA_IDS[kind],
            "msgId": msg_id,
            "deviceId": self.device_id,
            "seq": self._seq,
            "ts": self._clock().isoformat(timespec="milliseconds"),
            "data": data,
        }
        self._seq += 1
        payload = json.dumps(envelope, separators=(",", ":")).encode()
        return OutgoingMessage(topic_for(self.device_id, kind), payload, msg_id, kind, retain)

    def status(self, state: str) -> OutgoingMessage:
        return self._message(MessageKind.STATUS, {"state": state}, retain=True)

    def telemetry(self) -> OutgoingMessage:
        self._battery = max(0.0, self._battery - self._rng.uniform(0.0, 0.3))
        return self._message(
            MessageKind.TELEMETRY,
            {
                "batteryPct": round(self._battery, 1),
                "moistureRhPct": round(self._rng.uniform(30, 70), 1),
                "airTempC": round(self._rng.uniform(24, 38), 1),
                "bollsHarvestedTotal": self._bolls_total,
                "solarActive": self._rng.random() < 0.7,
            },
        )

    def pest(self) -> OutgoingMessage:
        x, y = self._rng.uniform(0, 0.8), self._rng.uniform(0, 0.8)
        return self._message(
            MessageKind.PEST,
            {
                "label": self._rng.choice(SIM_PEST_LABELS),
                "confidence": round(self._rng.uniform(0.5, 0.99), 2),
                "bbox": [round(x, 3), round(y, 3), round(self._rng.uniform(0.05, 0.2), 3), round(self._rng.uniform(0.05, 0.2), 3)],
            },
        )

    def spray(self, related_msg_id: str | None = None) -> OutgoingMessage:
        data: dict = {"durationMs": self._rng.randint(1000, 2000)}  # PPT: 1-2 s bursts
        if related_msg_id:
            data["relatedMsgId"] = related_msg_id
        return self._message(MessageKind.SPRAY, data)

    def harvest(self) -> OutgoingMessage:
        # Reports a simulated observation. "picked" follows maturity only: no moisture threshold
        # is applied because the agronomic threshold is unresolved (U-1).
        maturity = self._rng.choice(("mature", "immature", "partial"))
        picked = maturity == "mature"
        if picked:
            self._bolls_total += 1
        return self._message(
            MessageKind.HARVEST,
            {"maturity": maturity, "picked": picked, "moistureRhPct": round(self._rng.uniform(30, 70), 1)},
        )

    def scan(self, row: int = 1, segment: int = 1) -> OutgoingMessage:
        # Phase II: the cart closes one row segment and reports per-class counts.
        # Illustrative numbers only; a READY-looking segment about one time in three.
        closed = self._rng.randint(10, 50)
        opened = self._rng.randint(0, closed)
        started = self._clock().timestamp() - self._rng.uniform(60, 180)
        counts = {
            "bollClosed": closed,
            "bollCracking": self._rng.randint(0, 10),
            "bollOpen": opened,
            "bollBored": self._rng.randint(0, 2),
            "rosetteFlower": self._rng.randint(0, 2),
        }
        return self._message(
            MessageKind.SCAN,
            {
                "row": row,
                "segment": segment,
                "counts": {k: v for k, v in counts.items() if v},
                "startedAt": datetime.fromtimestamp(started, UTC).isoformat(timespec="milliseconds"),
                "frames": self._rng.randint(200, 900),
                "model": "sim-yolov8n",
                "airTempC": round(self._rng.uniform(24, 38), 1),
                "airRhPct": round(self._rng.uniform(40, 90), 1),
            },
        )

    def pick(self, row: int = 1, segment: int = 1) -> OutgoingMessage:
        # Phase II experiment E10: one robotic pick attempt (most succeed, some are aborted).
        self._pick_n += 1
        result = self._rng.choices(("completed", "unreachable", "aborted"), weights=(7, 2, 1))[0]
        data: dict = {
            "attemptId": f"sim-{self._pick_n:06d}",
            "result": result,
            "row": row,
            "segment": segment,
            "trackId": self._rng.randint(0, 500),
            "confidence": round(self._rng.uniform(0.5, 0.99), 2),
            "cycleS": round(self._rng.uniform(8, 25), 1),
        }
        if result != "completed":
            data["reason"] = "simulated: out of reach" if result == "unreachable" else "simulated: link lost"
        return self._message(MessageKind.PICK, data)

    def last_will(self) -> OutgoingMessage:
        """Offline status registered with the broker at connect time (published by the broker)."""
        return self.status("offline")
