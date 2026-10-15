"""Alert rules - pure functions, applied by the ingest service in the same transaction as the
source message (so alert creation is exactly-once together with the message).

Only rules traceable to the requirements are implemented:

| Alert            | Trigger                          | Source                                               |
|------------------|----------------------------------|------------------------------------------------------|
| pest_detected    | event/pest received              | Paper §III.B/§V.E pest alerts; PPT module 2 alerts   |
| spray_performed  | event/spray received             | PPT module 4 "notify the farmer via the mobile app"  |
| device_offline   | status = offline (incl. Will)    | Phase 0 offline detection; paper "system health"     |

Deliberately NOT implemented (need a decision, no threshold exists in the requirements):
low-battery alerts (threshold undefined) and moisture alerts (U-1 unresolved).
Detections are alerted as reported: the device applies its own confidence threshold upstream.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from gossy.contracts.topics import MessageKind

AlertType = Literal["pest_detected", "spray_performed", "device_offline"]
Severity = Literal["info", "warning"]


@dataclass(frozen=True)
class AlertDraft:
    alert_type: AlertType
    severity: Severity
    details: dict = field(default_factory=dict)


def derive_alerts(kind: MessageKind, data: dict) -> list[AlertDraft]:
    """``data`` is the validated payload in wire (camelCase) form."""
    if kind is MessageKind.PEST:
        return [AlertDraft("pest_detected", "warning", {"label": data["label"], "confidence": data["confidence"]})]
    if kind is MessageKind.SPRAY:
        details = {"durationMs": data["durationMs"]}
        if data.get("relatedMsgId"):
            details["relatedMsgId"] = data["relatedMsgId"]
        return [AlertDraft("spray_performed", "info", details)]
    if kind is MessageKind.STATUS and data.get("state") == "offline":
        return [AlertDraft("device_offline", "warning", {})]
    return []
