"""Security audit trail: every audit event is written to ``audit_log`` and to the structured log.

A failure to write the audit row is logged loudly but does not fail the user's request (the
structured log still carries the event).
"""

from __future__ import annotations

import logging
import uuid
from datetime import UTC, datetime
from typing import Literal

from sqlalchemy import insert
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.db.tables import audit_log
from gossy.logging_setup import request_id_var

log = logging.getLogger("gossy.audit")
Outcome = Literal["success", "failure", "denied"]


async def audit(
    engine: AsyncEngine,
    action: str,
    outcome: Outcome,
    *,
    actor: uuid.UUID | None = None,
    target: str | None = None,
    client_ip: str | None = None,
    details: dict | None = None,
) -> None:
    entry = {
        "ts": datetime.now(UTC),
        "actor_user_id": actor,
        "action": action,
        "outcome": outcome,
        "target": target[:128] if target else None,
        "request_id": request_id_var.get(),
        "client_ip": client_ip,
        "details": details or {},
    }
    level = logging.INFO if outcome == "success" else logging.WARNING
    log.log(level, "audit", extra={"action": action, "outcome": outcome, "actor": str(actor) if actor else None, "target": entry["target"], "client_ip": client_ip, "details": entry["details"]})
    try:
        async with engine.begin() as conn:
            await conn.execute(insert(audit_log).values(**entry))
    except Exception:
        log.exception("audit_write_failed", extra={"action": action})
