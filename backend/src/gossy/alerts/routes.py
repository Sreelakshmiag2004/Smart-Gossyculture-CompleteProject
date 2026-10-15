"""Alert retrieval and acknowledgement. Acknowledging only changes alert state; it never
reaches a device."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from pydantic import AwareDatetime
from sqlalchemy import and_, select, update
from sqlalchemy.types import String

from gossy.alerts.rules import AlertType
from gossy.alerts.schemas import Alert, AlertStatus, alert_from_row
from gossy.api.deps import CurrentPrincipal, service
from gossy.api.errors import ApiError, not_found, responses
from gossy.api.pagination import DEFAULT_LIMIT, MAX_LIMIT, Page, check_time_range
from gossy.audit import audit
from gossy.db.tables import alerts
from gossy.devices.service import DeviceService
from gossy.telemetry.queries import all_of, keyset_page, time_window

router = APIRouter(prefix="/api/v1", tags=["alerts"])
Devices = Annotated[DeviceService, Depends(service("devices"))]


async def _scope(principal, svc: DeviceService, device_id: str | None) -> list | None:
    if device_id is not None:
        await svc.require_device(principal, device_id)
        return [alerts.c.device_id == device_id]
    allowed = await svc.accessible_device_ids(principal)
    return [alerts.c.device_id.in_(sorted(allowed))] if allowed else None


@router.get("/alerts", response_model=Page[Alert], responses=responses(401, 404, 422), summary="Alerts for the caller's devices, newest first")
async def list_alerts(
    request: Request, principal: CurrentPrincipal, svc: Devices,
    device_id: Annotated[str | None, Query(alias="deviceId")] = None,
    status: Annotated[AlertStatus | None, Query()] = None,
    alert_type: Annotated[AlertType | None, Query(alias="type")] = None,
    start: Annotated[AwareDatetime | None, Query(alias="from")] = None,
    end: Annotated[AwareDatetime | None, Query(alias="to")] = None,
    limit: Annotated[int, Query(ge=1, le=MAX_LIMIT)] = DEFAULT_LIMIT,
    cursor: Annotated[str | None, Query(max_length=512)] = None,
) -> Page[Alert]:
    check_time_range(start, end)
    scope = await _scope(principal, svc, device_id)
    if scope is None:
        return Page[Alert](items=[], nextCursor=None)
    clauses = [*scope, *time_window(alerts.c.occurred_at, start, end)]
    if status:
        clauses.append(alerts.c.status == status)
    if alert_type:
        clauses.append(alerts.c.alert_type == alert_type)
    items, nxt = await keyset_page(
        request.app.state.engine, select(alerts).where(all_of(clauses)),
        time_col=alerts.c.occurred_at, key_col=alerts.c.id.cast(String), cursor=cursor, limit=limit,
        to_item=alert_from_row, key_of=lambda r: (r.occurred_at, str(r.id)),
    )
    return Page[Alert](items=items, nextCursor=nxt)


async def _get_accessible(request: Request, principal, svc: DeviceService, alert_id: uuid.UUID):
    async with request.app.state.engine.connect() as conn:
        row = (await conn.execute(select(alerts).where(alerts.c.id == alert_id))).first()
    if row is None:
        raise not_found("Alert")
    try:
        await svc.require_device(principal, row.device_id)
    except ApiError:
        raise not_found("Alert") from None
    return row


@router.get("/alerts/{alert_id}", response_model=Alert, responses=responses(401, 404, 422), summary="One alert")
async def get_alert(alert_id: uuid.UUID, request: Request, principal: CurrentPrincipal, svc: Devices) -> Alert:
    return alert_from_row(await _get_accessible(request, principal, svc, alert_id))


@router.post("/alerts/{alert_id}/acknowledge", response_model=Alert, responses=responses(401, 404, 422), summary="Mark an alert as acknowledged (idempotent)")
async def acknowledge_alert(alert_id: uuid.UUID, request: Request, principal: CurrentPrincipal, svc: Devices) -> Alert:
    await _get_accessible(request, principal, svc, alert_id)
    engine = request.app.state.engine
    async with engine.begin() as conn:
        await conn.execute(
            update(alerts).where(and_(alerts.c.id == alert_id, alerts.c.status == "open")).values(
                status="acknowledged", acknowledged_at=datetime.now(UTC), acknowledged_by=principal.user_id,
            )
        )
        row = (await conn.execute(select(alerts).where(alerts.c.id == alert_id))).one()
    await audit(engine, "alert.acknowledge", "success", actor=principal.user_id, target=str(alert_id))
    return alert_from_row(row)
