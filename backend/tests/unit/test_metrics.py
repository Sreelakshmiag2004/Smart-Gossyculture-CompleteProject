"""/metrics exposition and the ingestion alert conditions (retrying / prolonged / blocked / dead letter)."""

from datetime import timedelta
from types import SimpleNamespace

import pytest

from gossy.health.metrics import Metric, render
from gossy.ingest.metrics import ingest_metrics
from gossy.ingest.service import (
    CONDITION_BLOCKED, CONDITION_OK, CONDITION_PROLONGED, CONDITION_RETRYING, IngestStats, ingest_condition,
)
from tests.conftest import NOW


def test_render_prometheus_text():
    text = render([
        Metric.single("gossy_x_total", "counter", "things", 3),
        Metric("gossy_state", "gauge", "state", [({"condition": "ok"}, 1), ({"condition": 'we"ird'}, 0)]),
    ])
    assert text == (
        "# HELP gossy_x_total things\n# TYPE gossy_x_total counter\ngossy_x_total 3\n"
        '# HELP gossy_state state\n# TYPE gossy_state gauge\ngossy_state{condition="ok"} 1\ngossy_state{condition="we\\"ird"} 0\n'
    )


def test_render_rejects_invalid_names():
    with pytest.raises(ValueError):
        render([Metric.single("bad-name", "gauge", "x", 1)])


@pytest.mark.parametrize(
    "retrying_for,blocked,expected",
    [
        (None, False, CONDITION_OK),
        (10, False, CONDITION_RETRYING),  # temporary retry
        (299.9, False, CONDITION_RETRYING),
        (300, False, CONDITION_PROLONGED),  # prolonged blockage at the threshold
        (3600, False, CONDITION_PROLONGED),
        (None, True, CONDITION_BLOCKED),  # permanent: outcome cannot be made durable
        (10, True, CONDITION_BLOCKED),
    ],
)
def test_ingest_condition(retrying_for, blocked, expected):
    stats = IngestStats(
        retrying_since=NOW - timedelta(seconds=retrying_for) if retrying_for is not None else None,
        blocked_since=NOW if blocked else None,
    )
    assert ingest_condition(stats, NOW, prolonged_after_s=300) == expected


def test_ingest_metrics_condition_is_one_hot_and_dead_letters_are_counted():
    service = SimpleNamespace(stats=IngestStats(received=5, ingested=3, dead_lettered=1, retrying_since=NOW - timedelta(seconds=400), last_message_at=NOW))
    consumer = SimpleNamespace(acked=4, ack_failures=0, errors=0, connected=True, connect_count=2)
    metrics = {m.name: m for m in ingest_metrics(service, consumer, 300, clock=lambda: NOW)}
    condition = {labels["condition"]: value for labels, value in metrics["gossy_ingest_condition"].samples}
    assert condition == {"ok": 0, "retrying": 0, "prolonged": 1, "blocked": 0}
    assert metrics["gossy_ingest_dead_letters_total"].samples == [({}, 1)]
    assert metrics["gossy_ingest_retry_duration_seconds"].samples == [({}, 400)]
    assert metrics["gossy_ingest_mqtt_connected"].samples == [({}, 1.0)]


async def test_blocked_since_is_set_and_cleared_by_the_next_durable_outcome():
    from sqlalchemy import exc as sa_exc

    from gossy.config import IngestSettings
    from gossy.ingest.service import IngestService, ProcessingBlocked
    from tests.unit.test_service import FakeRepo, status_payload

    bug = lambda: sa_exc.ProgrammingError("x", {}, Exception("permission denied"))  # noqa: E731
    repo = FakeRepo(store_errors=[bug()], rejection_errors=[bug()])

    async def no_sleep(_):
        return None

    svc = IngestService(repo, IngestSettings(store_retry_attempts=1), clock=lambda: NOW, sleep=no_sleep)
    with pytest.raises(ProcessingBlocked):
        await svc.handle("bollbot/v1/sim-0001/status", status_payload())
    assert ingest_condition(svc.stats, NOW, 300) == CONDITION_BLOCKED
    await svc.handle("bollbot/v1/sim-0001/status", status_payload())  # redelivered, now succeeds
    assert ingest_condition(svc.stats, NOW, 300) == CONDITION_OK
