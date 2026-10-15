from __future__ import annotations

from datetime import datetime
from typing import Protocol

from sqlalchemy import insert, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.alerts.rules import derive_alerts
from gossy.alerts.schemas import alert_from_row
from gossy.contracts.topics import MessageKind
from gossy.db.tables import alerts, device_events, ingested_messages, rejected_messages, telemetry
from gossy.ingest.faults import BEFORE_TRANSACTION, DURING_TRANSACTION, NO_FAULTS, FaultInjector
from gossy.ingest.validation import ValidMessage
from gossy.realtime.events import CHANNEL, alert_json, event_message, notify_payload

EXCERPT_BYTES = 2048

_UPSERT_STATUS = text(
    """
    INSERT INTO device_status (device_id, state, state_at, last_seen_at, last_msg_id)
    VALUES (:device_id, :state, :state_at, :last_seen_at, :msg_id)
    ON CONFLICT (device_id) DO UPDATE SET
        last_seen_at = GREATEST(device_status.last_seen_at, EXCLUDED.last_seen_at),
        last_msg_id  = CASE WHEN EXCLUDED.last_seen_at IS NOT NULL THEN EXCLUDED.last_msg_id
                            ELSE device_status.last_msg_id END,
        state    = CASE WHEN EXCLUDED.state IS NOT NULL
                             AND (device_status.state_at IS NULL OR EXCLUDED.state_at > device_status.state_at)
                        THEN EXCLUDED.state ELSE device_status.state END,
        state_at = CASE WHEN EXCLUDED.state IS NOT NULL
                             AND (device_status.state_at IS NULL OR EXCLUDED.state_at > device_status.state_at)
                        THEN EXCLUDED.state_at ELSE device_status.state_at END
    """
)


class IngestRepository(Protocol):
    async def store(self, message: ValidMessage, received_at: datetime) -> bool:
        """Persist atomically. Returns False if msgId was already ingested (duplicate)."""

    async def store_rejection(self, *, topic: str, reason: str, detail: str | None, payload: bytes, received_at: datetime, full_payload: bool = False) -> None: ...


class SqlIngestRepository:
    def __init__(self, engine: AsyncEngine, faults: FaultInjector = NO_FAULTS):
        self._engine = engine
        self._faults = faults

    async def store(self, message: ValidMessage, received_at: datetime) -> bool:
        """One transaction: ledger row (dedupe) → typed row → device status → alerts → NOTIFY.

        NOTIFY is transactional, so the live event is only published if everything committed,
        and a duplicate message publishes nothing.
        """
        env = message.envelope
        data_json = env.data.model_dump(mode="json", by_alias=True, exclude_none=True)
        self._faults.check(BEFORE_TRANSACTION, env.msg_id)
        async with self._engine.begin() as conn:
            inserted = await conn.execute(
                pg_insert(ingested_messages)
                .values(
                    msg_id=env.msg_id,
                    device_id=env.device_id,
                    kind=message.kind.value,
                    schema_id=env.schema_id,
                    seq=env.seq,
                    device_ts=env.ts,
                    received_at=received_at,
                    data=data_json,
                )
                .on_conflict_do_nothing(index_elements=["msg_id"])
                .returning(ingested_messages.c.msg_id, ingested_messages.c.ingest_seq)
            )
            ledger = inserted.first()
            if ledger is None:
                return False

            if message.kind is MessageKind.TELEMETRY:
                d = env.data
                await conn.execute(
                    insert(telemetry).values(
                        time=env.ts,
                        device_id=env.device_id,
                        msg_id=env.msg_id,
                        battery_pct=d.battery_pct,
                        moisture_rh_pct=d.moisture_rh_pct,
                        air_temp_c=d.air_temp_c,
                        bolls_harvested_total=d.bolls_harvested_total,
                        solar_active=d.solar_active,
                        air_rh_pct=d.air_rh_pct,
                        dewpoint_c=d.dewpoint_c,
                    )
                )
            elif message.kind in (MessageKind.PEST, MessageKind.SPRAY, MessageKind.HARVEST, MessageKind.SCAN, MessageKind.PICK):
                await conn.execute(
                    insert(device_events).values(
                        time=env.ts,
                        device_id=env.device_id,
                        msg_id=env.msg_id,
                        event_type=message.kind.value.removeprefix("event/"),
                        data=data_json,
                    )
                )

            is_status = message.kind is MessageKind.STATUS
            # A broker-published "offline" Last Will is not evidence that the device was seen.
            seen = None if is_status and env.data.state == "offline" else received_at
            await conn.execute(
                _UPSERT_STATUS,
                {
                    "device_id": env.device_id,
                    "state": env.data.state if is_status else None,
                    # Status is ordered by RECEIPT time, not device time: the Last Will is built at
                    # connect time, so it always carries an older device timestamp than the later
                    # "online" announcement even though the broker delivers it afterwards.
                    "state_at": received_at if is_status else None,
                    "last_seen_at": seen,
                    "msg_id": env.msg_id,
                },
            )

            created_alerts = []
            for draft in derive_alerts(message.kind, data_json):
                row = (
                    await conn.execute(
                        pg_insert(alerts)
                        .values(
                            device_id=env.device_id, alert_type=draft.alert_type, severity=draft.severity, status="open",
                            source_msg_id=env.msg_id, occurred_at=env.ts, created_at=received_at, details=draft.details,
                        )
                        .on_conflict_do_nothing(constraint="uq_alerts_source_type")
                        .returning(alerts)
                    )
                ).first()
                if row is not None:
                    created_alerts.append(alert_json(alert_from_row(row)))

            event = event_message(
                cursor=ledger.ingest_seq, kind=message.kind.value, device_id=env.device_id, msg_id=env.msg_id,
                ts=env.ts, received_at=received_at, data=data_json, alerts_json=created_alerts,
            )
            await conn.execute(text("SELECT pg_notify(:channel, :payload)"), {"channel": CHANNEL, "payload": notify_payload(event)})
            self._faults.check(DURING_TRANSACTION, env.msg_id)
            return True

    async def store_rejection(self, *, topic: str, reason: str, detail: str | None, payload: bytes, received_at: datetime, full_payload: bool = False) -> None:
        """``full_payload`` keeps the whole (already size-limited) payload, so a dead-lettered
        message that passed validation can be replayed later; otherwise only an excerpt is kept."""
        async with self._engine.begin() as conn:
            await conn.execute(
                insert(rejected_messages).values(
                    received_at=received_at,
                    topic=topic[:256],
                    reason=reason[:64],
                    detail=(detail or "")[:512] or None,
                    payload_size=len(payload),
                    payload_excerpt=(payload if full_payload else payload[:EXCERPT_BYTES]).decode("utf-8", errors="replace"),
                )
            )
