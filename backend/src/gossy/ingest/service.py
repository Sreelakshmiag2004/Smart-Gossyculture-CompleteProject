"""Per-message ingestion: validate -> persist (idempotent) -> count and log every outcome.

Durability contract (Phase 2.5): ``handle`` returns ONLY when the outcome is durable in the
database, and the caller acknowledges the MQTT message (PUBACK) only after ``handle`` returns.

* ``INGESTED``   - the message and all its effects were committed in one transaction.
* ``DUPLICATE``  - the msgId was already committed earlier (redelivery after a crash/reconnect).
* ``REJECTED``   - invalid message; the rejection record was committed.
* ``DEAD_LETTERED`` - valid message that fails with a NON-transient error ``store_retry_attempts``
  times; the full payload was committed to ``rejected_messages`` for investigation/replay.

Transient database errors (database down, connection lost, deadlock, serialization failure)
are retried with capped exponential backoff and NO attempt limit, so a database outage delays
ingestion but cannot drop a message. If even the dead-letter record cannot be written,
``ProcessingBlocked`` is raised and the message is left unacknowledged.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from enum import StrEnum

from sqlalchemy import exc as sa_exc

from gossy.config import IngestSettings
from gossy.ingest.repository import IngestRepository
from gossy.ingest.validation import RejectedMessage, parse_message

log = logging.getLogger("gossy.ingest")


class Outcome(StrEnum):
    INGESTED = "ingested"
    DUPLICATE = "duplicate"
    REJECTED = "rejected"
    DEAD_LETTERED = "dead_lettered"


class ProcessingBlocked(Exception):
    """The outcome could not be made durable. The message must NOT be acknowledged."""


class _NonTransient(Exception):
    def __init__(self, cause: BaseException):
        super().__init__(type(cause).__name__)
        self.cause = cause


def is_transient(exc: BaseException) -> bool:
    """Errors that go away by themselves: retry without limit, never drop the message."""
    if isinstance(exc, sa_exc.DBAPIError) and exc.connection_invalidated:
        return True
    return isinstance(
        exc,
        (
            sa_exc.OperationalError,  # database unreachable/shutting down, deadlock, serialization failure
            sa_exc.InterfaceError,  # connection closed underneath us
            sa_exc.TimeoutError,  # pool exhausted
            ConnectionError,
            OSError,
            TimeoutError,
        ),
    )


@dataclass
class IngestStats:
    received: int = 0
    ingested: int = 0
    duplicates: int = 0
    rejected: int = 0
    dead_lettered: int = 0
    transient_retries: int = 0
    blocked: int = 0
    last_message_at: datetime | None = None
    retrying_since: datetime | None = None
    # Set when an outcome could not be made durable (ProcessingBlocked); cleared by the next
    # durable outcome. The message is then being redelivered and failing again.
    blocked_since: datetime | None = None
    last_dead_letter_at: datetime | None = None

    def snapshot(self) -> dict[str, object]:
        data = asdict(self)
        for key in ("last_message_at", "retrying_since", "blocked_since", "last_dead_letter_at"):
            data[key] = data[key].isoformat() if data[key] else None
        return data


# Ingestion condition, for monitoring/alerting (Phase 3). Exactly one is active at a time.
CONDITION_OK = "ok"
CONDITION_RETRYING = "retrying"  # temporary: transient DB errors, retrying for < prolonged_after_s
CONDITION_PROLONGED = "prolonged"  # transient retries for >= prolonged_after_s (outage still ongoing)
CONDITION_BLOCKED = "blocked"  # permanent: an outcome cannot be made durable; needs an operator
CONDITIONS = (CONDITION_OK, CONDITION_RETRYING, CONDITION_PROLONGED, CONDITION_BLOCKED)


def ingest_condition(stats: IngestStats, now: datetime, prolonged_after_s: float) -> str:
    """Dead letters are reported separately (a counter): the message was stored and
    acknowledged, so ingestion continues, but an operator must investigate it."""
    if stats.blocked_since is not None:
        return CONDITION_BLOCKED
    if stats.retrying_since is not None:
        waited = (now - stats.retrying_since).total_seconds()
        return CONDITION_PROLONGED if waited >= prolonged_after_s else CONDITION_RETRYING
    return CONDITION_OK


def _utcnow() -> datetime:
    return datetime.now(UTC)


class IngestService:
    def __init__(
        self,
        repository: IngestRepository,
        settings: IngestSettings,
        *,
        clock: Callable[[], datetime] = _utcnow,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        self._repo = repository
        self._settings = settings
        self._clock = clock
        self._sleep = sleep
        self.stats = IngestStats()

    async def handle(self, topic: str, payload: bytes) -> Outcome:
        now = self._clock()
        self.stats.received += 1
        self.stats.last_message_at = now
        try:
            message = parse_message(
                topic,
                payload,
                now=now,
                max_payload_bytes=self._settings.max_payload_bytes,
                max_future_skew=timedelta(seconds=self._settings.max_future_skew_s),
            )
        except RejectedMessage as rejection:
            log.warning("message_rejected", extra={"topic": topic, "reason": rejection.reason, "detail": rejection.detail, "size": len(payload)})
            await self._record_rejection(topic, rejection.reason, rejection.detail, payload, now, full_payload=False, context={"topic": topic})
            self.stats.rejected += 1
            self.stats.blocked_since = None
            return Outcome.REJECTED

        env = message.envelope
        context = {"device_id": env.device_id, "msg_id": env.msg_id, "kind": message.kind.value, "seq": env.seq}
        try:
            is_new = await self._durably(lambda: self._repo.store(message, now), context)
        except _NonTransient as failure:
            log.error("ingest_dead_letter", extra={**context, "error_type": type(failure.cause).__name__}, exc_info=failure.cause)
            await self._record_rejection(topic, "processing_failed", type(failure.cause).__name__, payload, now, full_payload=True, context=context)
            self.stats.dead_lettered += 1
            self.stats.last_dead_letter_at = self._clock()
            self.stats.blocked_since = None
            return Outcome.DEAD_LETTERED

        self.stats.blocked_since = None
        if is_new:
            self.stats.ingested += 1
            log.info("message_ingested", extra=context)
            return Outcome.INGESTED
        self.stats.duplicates += 1
        log.info("message_duplicate", extra=context)
        return Outcome.DUPLICATE

    async def _record_rejection(self, topic: str, reason: str, detail: str | None, payload: bytes, now: datetime, *, full_payload: bool, context: dict) -> None:
        try:
            await self._durably(
                lambda: self._repo.store_rejection(topic=topic, reason=reason, detail=detail, payload=payload, received_at=now, full_payload=full_payload),
                context,
            )
        except _NonTransient as failure:
            self.stats.blocked += 1
            self.stats.blocked_since = self.stats.blocked_since or self._clock()
            log.critical("rejection_store_failed_message_not_acknowledged", extra={**context, "reason": reason, "error_type": type(failure.cause).__name__})
            raise ProcessingBlocked(reason) from failure.cause

    async def _durably(self, operation: Callable[[], Awaitable[object]], context: dict):
        """Run ``operation`` until it succeeds. Transient errors: unlimited retries with capped
        backoff. Other errors: raise ``_NonTransient`` after ``store_retry_attempts``."""
        failures = 0
        transient = 0
        try:
            while True:
                try:
                    return await operation()
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    if is_transient(exc):
                        transient += 1
                        self.stats.transient_retries += 1
                        self.stats.retrying_since = self.stats.retrying_since or self._clock()
                        delay = min(self._settings.store_retry_backoff_s * 2 ** min(transient - 1, 16), self._settings.store_retry_max_backoff_s)
                        log.warning("ingest_retry_transient", extra={**context, "attempt": transient, "retry_in_s": delay, "error_type": type(exc).__name__})
                    else:
                        failures += 1
                        if failures >= self._settings.store_retry_attempts:
                            raise _NonTransient(exc) from exc
                        delay = self._settings.store_retry_backoff_s * 2 ** (failures - 1)
                        log.warning("ingest_retry_error", extra={**context, "attempt": failures, "retry_in_s": delay, "error_type": type(exc).__name__})
                    await self._sleep(delay)
        finally:
            if transient:
                self.stats.retrying_since = None
