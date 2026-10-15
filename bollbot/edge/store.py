"""Store-and-forward outbox on the cart (spec Section 11, experiment E8).

Every record is written to SQLite FIRST and only then uploaded, so nothing
is lost when 4G drops. Each record gets its contract msgId (ULID) and seq
when it is queued; a retry re-sends the SAME msgId, so the backend stores it
once (its ingestion is idempotent on msgId). Replacing a record with a newer
version (same kind + doc_id) gives it a new msgId and seq.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

_SCHEMA = """
CREATE TABLE IF NOT EXISTS outbox (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL,              -- scan | heartbeat | spray_event | ...
    doc_id     TEXT NOT NULL,
    payload    TEXT NOT NULL,              -- JSON
    created    REAL NOT NULL,              -- unix time
    attempts   INTEGER NOT NULL DEFAULT 0,
    sent       REAL,                       -- unix time, NULL = pending, -1 = dead letter
    last_error TEXT,
    msg_id     TEXT,                       -- contract msgId (ULID), fixed for every retry
    seq        INTEGER,                    -- per-device counter (contract 'seq')
    UNIQUE(kind, doc_id)
);
CREATE INDEX IF NOT EXISTS outbox_pending ON outbox(sent, id);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v INTEGER NOT NULL);
"""


@dataclass
class OutboxItem:
    id: int
    kind: str
    doc_id: str
    payload: dict
    attempts: int
    msg_id: str = ""
    seq: int = 0


class Outbox:
    def __init__(self, path: str | Path = ":memory:"):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        # check_same_thread=False + a lock: the cart loop writes, the sync thread reads.
        self._db = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self._db.execute("PRAGMA journal_mode=WAL")      # survives power loss better
        self._db.executescript(_SCHEMA)
        cols = {r[1] for r in self._db.execute("PRAGMA table_info(outbox)")}
        for col, typ in (("msg_id", "TEXT"), ("seq", "INTEGER")):   # upgrade an older outbox file
            if col not in cols:
                self._db.execute(f"ALTER TABLE outbox ADD COLUMN {col} {typ}")
        self._lock = threading.Lock()
        from .contract import new_ulid
        for (row_id,) in self._db.execute("SELECT id FROM outbox WHERE msg_id IS NULL").fetchall():
            self._db.execute("UPDATE outbox SET msg_id = ?, seq = ? WHERE id = ?",
                             (new_ulid(), self._next_seq_locked(), row_id))

    def next_seq(self) -> int:
        """Next value of the device's message counter (persists across restarts)."""
        with self._lock:
            return self._next_seq_locked()

    def _next_seq_locked(self) -> int:
        self._db.execute("INSERT INTO meta(k, v) VALUES ('seq', 0) ON CONFLICT(k) DO UPDATE SET v = v + 1")
        return int(self._db.execute("SELECT v FROM meta WHERE k = 'seq'").fetchone()[0])

    def put(self, kind: str, doc_id: str, payload: dict, now: Optional[float] = None) -> None:
        """Insert, or replace an unsent/sent record with the same (kind, doc_id).
        A replaced record becomes pending again (e.g. a newer heartbeat)."""
        from .contract import new_ulid
        data = json.dumps(payload, ensure_ascii=False, default=str)
        with self._lock:
            self._db.execute("BEGIN")
            try:
                seq = self._next_seq_locked()
                self._db.execute(
                    """INSERT INTO outbox(kind, doc_id, payload, created, msg_id, seq) VALUES (?,?,?,?,?,?)
                       ON CONFLICT(kind, doc_id) DO UPDATE SET
                         payload=excluded.payload, created=excluded.created,
                         msg_id=excluded.msg_id, seq=excluded.seq,
                         sent=NULL, attempts=0, last_error=NULL""",
                    (kind, doc_id, data, now if now is not None else time.time(), new_ulid(), seq))
                self._db.execute("COMMIT")
            except Exception:
                self._db.execute("ROLLBACK")
                raise

    def pending(self, limit: int = 20) -> list[OutboxItem]:
        with self._lock:
            rows = self._db.execute(
                "SELECT id, kind, doc_id, payload, attempts, msg_id, seq FROM outbox "
                "WHERE sent IS NULL ORDER BY id LIMIT ?", (limit,)).fetchall()
        return [OutboxItem(r[0], r[1], r[2], json.loads(r[3]), r[4], r[5] or "", r[6] or 0) for r in rows]

    def mark_sent(self, item_id: int, now: Optional[float] = None) -> None:
        with self._lock:
            self._db.execute("UPDATE outbox SET sent=?, last_error=NULL WHERE id=?",
                             (now if now is not None else time.time(), item_id))

    def mark_dead(self, item_id: int, error: str) -> None:
        """A record that can never be uploaded (e.g. unknown kind): set it aside
        so it does not block the queue. It stays in the database for inspection."""
        with self._lock:
            self._db.execute("UPDATE outbox SET sent=-1, attempts=attempts+1, last_error=? WHERE id=?",
                             (("DEAD: " + error)[:500], item_id))

    def mark_failed(self, item_id: int, error: str) -> None:
        with self._lock:
            self._db.execute("UPDATE outbox SET attempts=attempts+1, last_error=? WHERE id=?",
                             (error[:500], item_id))

    def stats(self) -> dict:
        with self._lock:
            pending, sent, dead = self._db.execute(
                "SELECT SUM(sent IS NULL), SUM(sent IS NOT NULL AND sent >= 0), SUM(sent < 0) "
                "FROM outbox").fetchone()
            last_err = self._db.execute(
                "SELECT last_error FROM outbox WHERE sent IS NULL AND last_error IS NOT NULL "
                "ORDER BY id DESC LIMIT 1").fetchone()
        return {"pending": pending or 0, "sent": sent or 0, "dead": dead or 0,
                "last_error": last_err[0] if last_err else None}

    def purge_sent(self, older_than_s: float, now: Optional[float] = None) -> int:
        """Delete records uploaded more than older_than_s ago (keeps the SD card small)."""
        cutoff = (now if now is not None else time.time()) - older_than_s
        with self._lock:
            cur = self._db.execute("DELETE FROM outbox WHERE sent IS NOT NULL AND sent >= 0 AND sent < ?",
                                   (cutoff,))
        return cur.rowcount

    def close(self) -> None:
        self._db.close()
