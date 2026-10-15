"""Ingest service metrics (``GET /metrics``) and the three ingestion alert conditions.

Alerting (deploy/aws/terraform/monitoring.tf) uses these series:

| Alert                          | Series                                           | Meaning                          |
|--------------------------------|--------------------------------------------------|----------------------------------|
| temporary retry (warning)      | gossy_ingest_condition{condition="retrying"} = 1 | transient DB errors, < threshold |
| prolonged blockage (critical)  | gossy_ingest_condition{condition="prolonged"} = 1| retrying for >= threshold        |
| permanent / blocked (critical) | gossy_ingest_condition{condition="blocked"} = 1  | outcome cannot be made durable   |
| dead letter (critical)         | increase(gossy_ingest_dead_letters_total) > 0    | message stored for investigation |

Counters are per process (they restart at 0 when the ingest process restarts).
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime

from gossy.health.metrics import Metric
from gossy.ingest.service import CONDITIONS, IngestService, ingest_condition


def ingest_metrics(service: IngestService, consumer, prolonged_after_s: float, clock: Callable[[], datetime] = lambda: datetime.now(UTC)) -> list[Metric]:
    s = service.stats
    now = clock()
    condition = ingest_condition(s, now, prolonged_after_s)
    retry_seconds = (now - s.retrying_since).total_seconds() if s.retrying_since else 0.0
    last_message_age = (now - s.last_message_at).total_seconds() if s.last_message_at else -1.0
    counter = lambda name, help, value: Metric.single(name, "counter", help, value)  # noqa: E731
    gauge = lambda name, help, value: Metric.single(name, "gauge", help, value)  # noqa: E731
    return [
        counter("gossy_ingest_received_total", "MQTT messages received", s.received),
        counter("gossy_ingest_ingested_total", "Messages committed (first time)", s.ingested),
        counter("gossy_ingest_duplicates_total", "Redelivered/re-sent messages recognised by msgId", s.duplicates),
        counter("gossy_ingest_rejected_total", "Invalid messages (rejection recorded)", s.rejected),
        counter("gossy_ingest_dead_letters_total", "Valid messages dead-lettered after non-transient errors", s.dead_lettered),
        counter("gossy_ingest_transient_retries_total", "Retries caused by transient database errors", s.transient_retries),
        counter("gossy_ingest_blocked_total", "Times an outcome could not be made durable", s.blocked),
        counter("gossy_ingest_mqtt_acked_total", "PUBACKs sent after a durable outcome", consumer.acked),
        counter("gossy_ingest_mqtt_ack_failures_total", "PUBACKs that could not be sent (message will be redelivered)", consumer.ack_failures),
        counter("gossy_ingest_consumer_errors_total", "Unexpected consumer errors (connection dropped, message not acknowledged)", consumer.errors),
        gauge("gossy_ingest_mqtt_connected", "1 if connected to the broker", 1.0 if consumer.connected else 0.0),
        counter("gossy_ingest_mqtt_connects_total", "Successful broker connections", consumer.connect_count),
        gauge("gossy_ingest_retry_duration_seconds", "How long the current message has been retried (0 if not retrying)", retry_seconds),
        gauge("gossy_ingest_last_message_age_seconds", "Seconds since the last received message (-1 if none)", last_message_age),
        Metric("gossy_ingest_condition", "gauge", "Ingestion condition (exactly one is 1)", [({"condition": c}, 1.0 if c == condition else 0.0) for c in CONDITIONS]),
    ]
