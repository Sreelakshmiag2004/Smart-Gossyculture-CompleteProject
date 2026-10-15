"""Deterministic failure injection for the ingest process (development/test ONLY).

Refused in staging/production by ``enforce_environment_rules``. Disabled unless
``GOSSY_INGEST_FAULT_INJECTION_DIR`` is set.

A test arms a fault by writing a file named after a message's ``msgId`` into that directory,
containing one of the ``POINTS``. When the ingest process reaches that point for that message,
it renames the file to ``<msgId>.fired`` (so the fault fires exactly once, even though the
message will be redelivered) and terminates immediately with ``os._exit`` - no cleanup, no
PUBACK, no transaction commit: the same effect as a crash or ``kill -9``.

The database is never modified by the injector; recovery relies only on the production path
(broker redelivery of the unacknowledged message + the msgId idempotency ledger).
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

log = logging.getLogger("gossy.ingest.faults")

BEFORE_TRANSACTION = "before_transaction"  # A: message received, no transaction started
DURING_TRANSACTION = "during_transaction"  # B: all rows written + NOTIFY queued, not committed
AFTER_COMMIT = "after_commit"  # C: committed, PUBACK not yet sent
POINTS = (BEFORE_TRANSACTION, DURING_TRANSACTION, AFTER_COMMIT)
EXIT_CODE = 70


class FaultInjector:
    def __init__(self, directory: Path | None):
        self._dir = directory

    @property
    def enabled(self) -> bool:
        return self._dir is not None

    def check(self, point: str, msg_id: str) -> None:
        if self._dir is None:
            return
        armed = self._dir / msg_id
        try:
            wanted = armed.read_text(encoding="utf-8").strip()
        except OSError:
            return
        if wanted != point:
            return
        armed.rename(self._dir / f"{msg_id}.fired")
        log.critical("fault_injected_process_exit", extra={"point": point, "msg_id": msg_id})
        for handler in logging.getLogger().handlers:
            handler.flush()
        os._exit(EXIT_CODE)


NO_FAULTS = FaultInjector(None)
