from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import Field

from gossy.alerts.rules import AlertType, Severity
from gossy.auth.schemas import ApiModel

AlertStatus = Literal["open", "acknowledged"]


class Alert(ApiModel):
    id: uuid.UUID
    type: AlertType
    severity: Severity
    status: AlertStatus
    device_id: str
    occurred_at: datetime = Field(description="Device timestamp of the source message")
    created_at: datetime = Field(description="When the backend created the alert")
    source_msg_id: str = Field(description="Message that produced this alert (idempotency key)")
    details: dict
    acknowledged_at: datetime | None = None


def alert_from_row(row) -> Alert:
    return Alert(
        id=row.id, type=row.alert_type, severity=row.severity, status=row.status, device_id=row.device_id,
        occurred_at=row.occurred_at, created_at=row.created_at, source_msg_id=row.source_msg_id,
        details=row.details, acknowledged_at=row.acknowledged_at,
    )
