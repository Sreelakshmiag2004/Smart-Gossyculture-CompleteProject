from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from pydantic import AwareDatetime
from sqlalchemy import cast, select
from sqlalchemy.types import Float

from gossy.api.deps import CurrentPrincipal, service
from gossy.api.errors import responses
from gossy.api.pagination import DEFAULT_LIMIT, MAX_LIMIT, Page, check_time_range
from gossy.db.tables import device_events, ingested_messages, telemetry
from gossy.devices.service import DeviceService
from gossy.telemetry.queries import all_of, keyset_page, time_window
from gossy.telemetry.schemas import DeviceEvent, Detection, EventType, TelemetryPoint

router = APIRouter(prefix="/api/v1")
Devices = Annotated[DeviceService, Depends(service("devices"))]
From = Annotated[AwareDatetime | None, Query(alias="from", description="Inclusive start (RFC 3339 with timezone)")]
To = Annotated[AwareDatetime | None, Query(alias="to", description="Exclusive end (RFC 3339 with timezone)")]
Limit = Annotated[int, Query(ge=1, le=MAX_LIMIT)]
Cursor = Annotated[str | None, Query(max_length=512, description="Opaque cursor from a previous page's nextCursor")]


def _engine(request: Request):
    return request.app.state.engine


@router.get("/devices/{device_id}/telemetry", response_model=Page[TelemetryPoint], responses=responses(401, 404, 422), tags=["telemetry"], summary="Telemetry for one device, newest first")
async def device_telemetry(
    device_id: str, request: Request, principal: CurrentPrincipal, svc: Devices,
    start: From = None, end: To = None, limit: Limit = DEFAULT_LIMIT, cursor: Cursor = None,
) -> Page[TelemetryPoint]:
    check_time_range(start, end)
    await svc.require_device(principal, device_id)
    # The receipt time lives in the ingestion ledger: every telemetry row is written in the same
    # transaction as its ledger row, so the join never drops a reading.
    query = (
        select(telemetry, ingested_messages.c.received_at)
        .join(ingested_messages, ingested_messages.c.msg_id == telemetry.c.msg_id)
        .where(all_of([telemetry.c.device_id == device_id, *time_window(telemetry.c.time, start, end)]))
    )
    items, nxt = await keyset_page(
        _engine(request), query, time_col=telemetry.c.time, key_col=telemetry.c.msg_id, cursor=cursor, limit=limit,
        to_item=lambda r: TelemetryPoint(
            time=r.time, received_at=r.received_at, msg_id=r.msg_id, battery_pct=r.battery_pct, moisture_rh_pct=r.moisture_rh_pct,
            air_temp_c=r.air_temp_c, bolls_harvested_total=r.bolls_harvested_total, solar_active=r.solar_active,
            air_rh_pct=r.air_rh_pct, dewpoint_c=r.dewpoint_c,
        ),
        key_of=lambda r: (r.time, r.msg_id),
    )
    return Page[TelemetryPoint](items=items, nextCursor=nxt)


@router.get("/devices/{device_id}/events", response_model=Page[DeviceEvent], responses=responses(401, 404, 422), tags=["telemetry"], summary="Pest, spray, harvest, scan and pick events for one device, newest first")
async def device_events_list(
    device_id: str, request: Request, principal: CurrentPrincipal, svc: Devices,
    types: Annotated[list[EventType] | None, Query(alias="type", description="Repeat to select several types")] = None,
    start: From = None, end: To = None, limit: Limit = DEFAULT_LIMIT, cursor: Cursor = None,
) -> Page[DeviceEvent]:
    check_time_range(start, end)
    await svc.require_device(principal, device_id)
    clauses = [device_events.c.device_id == device_id, *time_window(device_events.c.time, start, end)]
    if types:
        clauses.append(device_events.c.event_type.in_(types))
    items, nxt = await keyset_page(
        _engine(request), select(device_events).where(all_of(clauses)),
        time_col=device_events.c.time, key_col=device_events.c.msg_id, cursor=cursor, limit=limit,
        to_item=lambda r: DeviceEvent(time=r.time, msg_id=r.msg_id, device_id=r.device_id, type=r.event_type, data=r.data),
        key_of=lambda r: (r.time, r.msg_id),
    )
    return Page[DeviceEvent](items=items, nextCursor=nxt)


@router.get("/detections", response_model=Page[Detection], responses=responses(401, 404, 422), tags=["detections"], summary="Pest/disease detections reported by devices, newest first")
async def detections(
    request: Request, principal: CurrentPrincipal, svc: Devices,
    device_id: Annotated[str | None, Query(alias="deviceId")] = None,
    label: Annotated[str | None, Query(max_length=64, pattern=r"^[a-z0-9][a-z0-9_-]*$")] = None,
    min_confidence: Annotated[float | None, Query(alias="minConfidence", ge=0, le=1)] = None,
    start: From = None, end: To = None, limit: Limit = DEFAULT_LIMIT, cursor: Cursor = None,
) -> Page[Detection]:
    check_time_range(start, end)
    if device_id is not None:
        await svc.require_device(principal, device_id)
        scope = [device_events.c.device_id == device_id]
    else:
        allowed = await svc.accessible_device_ids(principal)
        if not allowed:
            return Page[Detection](items=[], nextCursor=None)
        scope = [device_events.c.device_id.in_(sorted(allowed))]
    clauses = [*scope, device_events.c.event_type == "pest", *time_window(device_events.c.time, start, end)]
    if label is not None:
        clauses.append(device_events.c.data["label"].astext == label)
    if min_confidence is not None:
        clauses.append(cast(device_events.c.data["confidence"].astext, Float) >= min_confidence)
    items, nxt = await keyset_page(
        _engine(request), select(device_events).where(all_of(clauses)),
        time_col=device_events.c.time, key_col=device_events.c.msg_id, cursor=cursor, limit=limit,
        to_item=lambda r: Detection(
            id=r.msg_id, device_id=r.device_id, detected_at=r.time, label=r.data["label"],
            confidence=r.data["confidence"], bbox=r.data.get("bbox"),
        ),
        key_of=lambda r: (r.time, r.msg_id),
    )
    return Page[Detection](items=items, nextCursor=nxt)

