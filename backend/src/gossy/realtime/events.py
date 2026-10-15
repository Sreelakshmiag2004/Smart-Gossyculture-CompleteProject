"""WebSocket event schema and loading.

One event per ingested message, identified by ``cursor`` (the ledger's server-assigned
``ingest_seq``: strictly increasing, gap-tolerant). Alerts created from that message travel
inside the event. The same builder is used for live delivery (via PostgreSQL NOTIFY) and for
replay after reconnect, so both produce identical documents.
"""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.alerts.schemas import Alert, alert_from_row
from gossy.db.tables import alerts, ingested_messages

CHANNEL = "gossy_events"
# PostgreSQL NOTIFY payloads must stay below 8000 bytes; larger events are sent as a reference
# and loaded from the database by the API.
NOTIFY_MAX_BYTES = 7500


def event_message(*, cursor: int, kind: str, device_id: str, msg_id: str, ts: datetime, received_at: datetime, data: dict | None, alerts_json: list[dict]) -> dict:
    return {
        "type": "event",
        "cursor": cursor,
        "kind": kind,
        "deviceId": device_id,
        "msgId": msg_id,
        "ts": ts.isoformat(),
        "receivedAt": received_at.isoformat(),
        "data": data,
        "alerts": alerts_json,
    }


def alert_json(alert: Alert) -> dict:
    return alert.model_dump(mode="json", by_alias=True)


def notify_payload(message: dict) -> str:
    text = json.dumps(message, separators=(",", ":"))
    if len(text.encode()) <= NOTIFY_MAX_BYTES:
        return text
    return json.dumps({"type": "event", "cursor": message["cursor"], "deviceId": message["deviceId"], "truncated": True})


async def load_events(engine: AsyncEngine, device_ids: set[str] | None, *, after: int, limit: int) -> list[dict]:
    """Events with cursor > ``after`` in cursor order. ``device_ids=None`` means all devices."""
    if device_ids is not None and not device_ids:
        return []
    query = select(ingested_messages).where(ingested_messages.c.ingest_seq > after)
    if device_ids is not None:
        query = query.where(ingested_messages.c.device_id.in_(sorted(device_ids)))
    query = query.order_by(ingested_messages.c.ingest_seq).limit(limit)
    async with engine.connect() as conn:
        rows = list(await conn.execute(query))
        by_msg: dict[str, list[dict]] = defaultdict(list)
        if rows:
            for a in await conn.execute(select(alerts).where(alerts.c.source_msg_id.in_([r.msg_id for r in rows])).order_by(alerts.c.created_at)):
                by_msg[a.source_msg_id].append(alert_json(alert_from_row(a)))
    return [
        event_message(
            cursor=r.ingest_seq, kind=r.kind, device_id=r.device_id, msg_id=r.msg_id,
            ts=r.device_ts, received_at=r.received_at, data=r.data, alerts_json=by_msg.get(r.msg_id, []),
        )
        for r in rows
    ]


async def latest_cursor(engine: AsyncEngine, device_ids: set[str] | None) -> int:
    query = select(func.coalesce(func.max(ingested_messages.c.ingest_seq), 0))
    if device_ids is not None:
        if not device_ids:
            return 0
        query = query.where(ingested_messages.c.device_id.in_(sorted(device_ids)))
    async with engine.connect() as conn:
        return int((await conn.execute(query)).scalar_one())


# ----------------------------------------------------------------------------- documentation models
class WsEvent(BaseModel):
    type: Literal["event"] = "event"
    cursor: int = Field(description="Server-assigned, strictly increasing. Resume with the last cursor you processed.")
    kind: Literal["telemetry", "event/pest", "event/spray", "event/harvest", "event/scan", "event/pick", "status"]
    deviceId: str
    msgId: str
    ts: datetime = Field(description="Device timestamp")
    receivedAt: datetime
    data: dict | None
    alerts: list[Alert]
