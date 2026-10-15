import json
import logging

from gossy.logging_setup import REDACTED, JsonFormatter, request_id_var


def _format(msg, **extra):
    record = logging.getLogger("t").makeRecord("t", logging.INFO, __file__, 1, msg, None, None, extra=extra)
    return json.loads(JsonFormatter().format(record))


def test_json_log_has_core_fields_and_extras():
    entry = _format("message_ingested", device_id="sim-0001", msg_id="01ABC")
    assert entry["event"] == "message_ingested"
    assert entry["level"] == "INFO"
    assert entry["device_id"] == "sim-0001" and entry["msg_id"] == "01ABC"
    assert entry["ts"].endswith("+00:00")


def test_secret_like_keys_are_redacted():
    entry = _format("x", password="p", db_password="p2", auth_token="t", api_key="k")
    assert {entry[k] for k in ("password", "db_password", "auth_token", "api_key")} == {REDACTED}


def test_request_id_included_when_set():
    token = request_id_var.set("req-12345678")
    try:
        assert _format("x")["request_id"] == "req-12345678"
    finally:
        request_id_var.reset(token)


def test_exception_is_serialised():
    try:
        raise ValueError("boom")
    except ValueError:
        import sys

        record = logging.getLogger("t").makeRecord("t", logging.ERROR, __file__, 1, "failed", None, sys.exc_info())
    entry = json.loads(JsonFormatter().format(record))
    assert entry["exc_type"] == "ValueError" and "boom" in entry["exc"]
