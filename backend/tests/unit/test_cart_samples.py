"""Contract test across repositories: messages produced by the REAL cart code (bollbot,
Modules 3-5) must pass the backend's full ingestion validation unchanged.

Refresh the fixture from the bollbot repository whenever either side changes:
    python -m bollbot.tools.export_contract_samples > backend/tests/fixtures/cart_samples.json
"""

import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from gossy.contracts.topics import MessageKind
from gossy.ingest.validation import parse_message

SAMPLES = json.loads((Path(__file__).resolve().parents[1] / "fixtures" / "cart_samples.json").read_text(encoding="utf-8"))
NOW = datetime(2026, 9, 29, 12, 0, tzinfo=UTC)


def _ids(s):
    return f"{s['source']}-{s['envelope']['seq']}"


@pytest.mark.parametrize("sample", SAMPLES, ids=[_ids(s) for s in SAMPLES])
def test_cart_message_is_accepted(sample):
    payload = json.dumps(sample["envelope"]).encode()
    msg = parse_message(sample["topic"], payload, now=NOW, max_payload_bytes=65536, max_future_skew=timedelta(minutes=5))
    assert msg.envelope.device_id == "cart01"
    assert msg.envelope.msg_id == sample["envelope"]["msgId"]


def test_fixture_covers_every_cart_message_kind():
    kinds = {s["topic"].split("/", 3)[3] for s in SAMPLES}
    assert kinds == {MessageKind.TELEMETRY.value, MessageKind.SCAN.value, MessageKind.SPRAY.value, MessageKind.PICK.value}
