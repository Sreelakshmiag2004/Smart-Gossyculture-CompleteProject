"""IngestService durability semantics: an outcome is returned only once it is durable."""

from datetime import datetime

import pytest
from sqlalchemy import exc as sa_exc

from gossy.config import IngestSettings
from gossy.contracts.messages import SCHEMA_IDS
from gossy.contracts.topics import MessageKind
from gossy.ingest.service import IngestService, Outcome, ProcessingBlocked, is_transient
from gossy.ingest.validation import ValidMessage
from tests.conftest import NOW, as_bytes, envelope

TOPIC = "bollbot/v1/sim-0001/status"


def db_down() -> Exception:
    return sa_exc.OperationalError("INSERT ...", {}, ConnectionRefusedError("connection refused"))


def bug() -> Exception:
    return sa_exc.ProgrammingError("INSERT ...", {}, Exception("permission denied for table telemetry"))


class FakeRepo:
    """In-memory stand-in with the real repository's contract: store() is atomic and returns
    False for an already-committed msgId."""

    def __init__(self, store_errors=(), rejection_errors=()):
        self.committed: set[str] = set()
        self.rejections: list[dict] = []
        self.store_errors = list(store_errors)
        self.rejection_errors = list(rejection_errors)
        self.store_calls = 0

    async def store(self, message: ValidMessage, received_at: datetime) -> bool:
        self.store_calls += 1
        if self.store_errors:
            raise self.store_errors.pop(0)
        if message.envelope.msg_id in self.committed:
            return False
        self.committed.add(message.envelope.msg_id)
        return True

    async def store_rejection(self, **kwargs) -> None:
        if self.rejection_errors:
            raise self.rejection_errors.pop(0)
        self.rejections.append(kwargs)


class Sleeps:
    def __init__(self):
        self.delays: list[float] = []

    async def __call__(self, delay):
        self.delays.append(delay)


def service(repo, sleep=None, **settings):
    return IngestService(repo, IngestSettings(store_retry_backoff_s=0.5, store_retry_max_backoff_s=30, **settings), clock=lambda: NOW, sleep=sleep or Sleeps())


def status_payload(**overrides):
    return as_bytes(envelope(SCHEMA_IDS[MessageKind.STATUS], "sim-0001", {"state": "online"}, **overrides))


async def test_ingests_then_detects_duplicate():
    repo = FakeRepo()
    svc = service(repo)
    payload = status_payload()
    assert await svc.handle(TOPIC, payload) is Outcome.INGESTED
    assert await svc.handle(TOPIC, payload) is Outcome.DUPLICATE
    assert svc.stats.ingested == 1 and svc.stats.duplicates == 1 and svc.stats.received == 2
    assert len(repo.committed) == 1


async def test_rejection_is_recorded_before_returning():
    repo = FakeRepo()
    svc = service(repo)
    assert await svc.handle(TOPIC, b"{bad") is Outcome.REJECTED
    assert svc.stats.rejected == 1
    assert repo.rejections[0]["reason"] == "schema_validation_failed" and repo.rejections[0]["full_payload"] is False


async def test_database_outage_is_retried_without_limit_and_nothing_is_lost():
    # 50 consecutive "database down" errors - far beyond the old 5-attempt budget.
    repo = FakeRepo(store_errors=[db_down() for _ in range(50)])
    sleeps = Sleeps()
    svc = service(repo, sleep=sleeps, store_retry_attempts=5)
    assert await svc.handle(TOPIC, status_payload()) is Outcome.INGESTED
    assert repo.store_calls == 51 and len(repo.committed) == 1
    assert svc.stats.transient_retries == 50 and svc.stats.retrying_since is None
    # capped exponential backoff: 0.5, 1, 2, ... then never above the cap
    assert sleeps.delays[:4] == [0.5, 1.0, 2.0, 4.0] and max(sleeps.delays) == 30


async def test_rejection_record_survives_database_outage():
    repo = FakeRepo(rejection_errors=[db_down() for _ in range(10)])
    svc = service(repo)
    assert await svc.handle(TOPIC, b"{bad") is Outcome.REJECTED
    assert len(repo.rejections) == 1


async def test_non_transient_error_is_dead_lettered_with_full_payload():
    repo = FakeRepo(store_errors=[bug() for _ in range(3)])
    svc = service(repo, store_retry_attempts=3)
    payload = status_payload()
    assert await svc.handle(TOPIC, payload) is Outcome.DEAD_LETTERED
    assert repo.store_calls == 3 and svc.stats.dead_lettered == 1
    dead = repo.rejections[0]
    assert dead["reason"] == "processing_failed" and dead["full_payload"] is True and dead["payload"] == payload


async def test_non_transient_error_that_recovers_is_ingested():
    repo = FakeRepo(store_errors=[bug()])
    svc = service(repo, store_retry_attempts=3)
    assert await svc.handle(TOPIC, status_payload()) is Outcome.INGESTED


async def test_blocked_when_even_the_dead_letter_cannot_be_written():
    repo = FakeRepo(store_errors=[bug(), bug()], rejection_errors=[bug(), bug()])
    svc = service(repo, store_retry_attempts=2)
    with pytest.raises(ProcessingBlocked):
        await svc.handle(TOPIC, status_payload())
    assert svc.stats.blocked == 1 and repo.rejections == [] and repo.committed == set()


def test_transient_classification():
    assert is_transient(db_down())
    assert is_transient(sa_exc.InterfaceError("x", {}, Exception("connection closed")))
    assert is_transient(ConnectionResetError())
    assert not is_transient(bug())
    assert not is_transient(sa_exc.IntegrityError("x", {}, Exception("unique violation")))
    assert not is_transient(ValueError("bad"))


async def test_stats_snapshot_is_json_friendly():
    svc = service(FakeRepo())
    await svc.handle(TOPIC, status_payload())
    snap = svc.stats.snapshot()
    assert snap["ingested"] == 1 and snap["last_message_at"] == NOW.isoformat()
    assert {"dead_lettered", "transient_retries", "blocked", "retrying_since"} <= set(snap)
