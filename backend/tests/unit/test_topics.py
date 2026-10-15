import pytest

from gossy.contracts.topics import (
    INGEST_SUBSCRIPTIONS,
    MessageKind,
    TopicError,
    parse_topic,
    topic_for,
    topic_matches,
)


@pytest.mark.parametrize("kind", list(MessageKind))
def test_topic_roundtrip(kind):
    topic = topic_for("sim-0001", kind)
    assert topic == f"bollbot/v1/sim-0001/{kind.value}"
    parsed = parse_topic(topic)
    assert parsed.device_id == "sim-0001" and parsed.kind is kind


@pytest.mark.parametrize("kind", list(MessageKind))
def test_ingest_subscriptions_cover_every_kind(kind):
    topic = topic_for("bb-000123", kind)
    assert sum(topic_matches(s, topic) for s in INGEST_SUBSCRIPTIONS) == 1


@pytest.mark.parametrize(
    "topic",
    [
        "other/v1/sim-0001/telemetry",
        "bollbot/v2/sim-0001/telemetry",
        "bollbot/v1/sim-0001/command",
        "bollbot/v1/sim-0001/config",
        "bollbot/v1/sim-0001/event/unknown",
        "bollbot/v1/SIM-0001/telemetry",
        "bollbot/v1/ab/telemetry",
        "bollbot/v1/svc-ingest/telemetry",
        "bollbot/v1/sim-0001",
    ],
)
def test_parse_topic_rejects(topic):
    with pytest.raises(TopicError):
        parse_topic(topic)


def test_no_command_or_config_kinds_exist():
    # v1 is ingestion-only: no kind may describe a cloud-to-device channel.
    assert not any(word in k.value for k in MessageKind for word in ("command", "cmd", "config", "control"))


def test_topic_for_rejects_service_accounts():
    with pytest.raises(TopicError):
        topic_for("svc-ingest", MessageKind.TELEMETRY)


def test_topic_matches_wildcards():
    assert topic_matches("a/+/c", "a/b/c")
    assert topic_matches("a/#", "a/b/c")
    assert not topic_matches("a/+", "a/b/c")
    assert not topic_matches("a/b/c/d", "a/b/c")
