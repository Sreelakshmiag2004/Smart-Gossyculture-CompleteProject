"""v1 boundary: the API process cannot talk to devices at all."""

import subprocess
import sys

from gossy.contracts.topics import MessageKind
from gossy.realtime.routes import ALLOWED_OPS


def test_api_process_does_not_load_any_mqtt_client():
    code = (
        "import sys, gossy.api.app;"
        "bad=[m for m in sys.modules if m.split('.')[0] in ('aiomqtt','paho') or m.startswith('gossy.ingest') or m.startswith('gossy_sim')];"
        "print(','.join(bad))"
    )
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout.strip()
    assert out == "", f"API process imports device-side/MQTT modules: {out}"


def test_websocket_accepts_only_read_operations():
    assert ALLOWED_OPS == ("start", "resume", "ping")


def test_ingest_consumer_only_acknowledges_never_publishes():
    # Phase 2.5 added manual PUBACK; the ingest client must still have no publish code path.
    import inspect

    from gossy.ingest import consumer

    source = inspect.getsource(consumer)
    assert ".publish(" not in source and "will_set" not in source


def test_contract_has_no_cloud_to_device_kind():
    assert {k.value for k in MessageKind} == {"telemetry", "event/pest", "event/spray", "event/harvest", "event/scan", "event/pick", "status"}
