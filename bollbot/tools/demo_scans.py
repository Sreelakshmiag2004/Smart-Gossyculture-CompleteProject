"""Send a short, realistic cart pass to the backend broker, through the cart's own upload path
(outbox -> SyncService -> MqttCloudUploader, contract bollbot/v1). For demos and for checking a
new broker login; no camera, model or Pi needed.

Row 3 ends up READY / BUILDING, row 4 NOT READY, with the cart's air reading (31 C, 55 % RH);
one heartbeat goes first.

    python -m bollbot.tools.demo_scans --password-file bollbot/secrets/device_password \
        --ca bollbot/secrets/broker-ca.crt            # dev stack on this PC: 127.0.0.1:18883

E8 load mode (IoT reliability): --repeat N passes, one every --every seconds, kept in a
persistent --outbox file, so messages created while the network is down wait on disk and are
sent when it returns - exactly as on the cart. Afterwards copy that file to
experiments/E8/outbox.sqlite for the reconciliation (experiments/E8/README.md).

Requires: pip install paho-mqtt
"""
from __future__ import annotations

import argparse
import logging
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

from bollbot.core.rules import IST, dew_point_c
from bollbot.edge.store import Outbox
from bollbot.edge.sync import MqttCloudUploader, SyncService

# (row, segment, open, cracking, closed): R = open / (open + cracking + closed)
PASS = [
    (3, 1, 20, 2, 8),    # R = 0.67 -> READY
    (3, 2, 9, 6, 15),    # R = 0.30 -> BUILDING
    (4, 1, 1, 2, 30),    # R = 0.03 -> NOT READY
]


def records(now: datetime, t_c: float = 31.0, rh: float = 55.0, tag: str = "") -> list[tuple[str, str, dict]]:
    """(kind, doc_id, payload) in the cart's outbox format, segments closed 2 minutes apart.
    [tag] makes the doc ids unique for repeated passes (E8 load mode)."""
    weather = {"t_c": t_c, "rh": rh, "dewpoint_c": dew_point_c(t_c, rh)}
    out = [("heartbeat", "demo-heartbeat", {"ts": now.isoformat(), "fps": 4.0, "outbox": {"pending": len(PASS)}, "weather": weather})]
    for i, (row, seg, opened, cracking, closed) in enumerate(PASS):
        ts = now - timedelta(minutes=2 * (len(PASS) - 1 - i))
        out.append(("scan", f"demo-R{row:03d}-S{seg:02d}-{ts:%Y%m%dT%H%M%S}{tag}", {
            "row": row, "segment": seg, "ts": ts.isoformat(), "started": (ts - timedelta(minutes=2)).isoformat(),
            "counts": {"boll_open": opened, "boll_cracking": cracking, "boll_closed": closed},
            "frames": 240, "model": "demo", "weather": weather,
        }))
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--device", default="cart01", help="device id = broker username (default cart01)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18883, help="dev stack: 18883; production: 8883")
    p.add_argument("--ca", required=True, help="CA certificate of the broker")
    p.add_argument("--password-file", required=True, help="file with the device's broker password")
    p.add_argument("--timeout", type=float, default=30.0, help="seconds to keep trying after the last pass")
    p.add_argument("--outbox", default=":memory:", help="outbox file (E8: keeps unsent messages across outages)")
    p.add_argument("--repeat", type=int, default=1, help="number of passes (E8: e.g. 400)")
    p.add_argument("--every", type=float, default=10.0, help="seconds between passes")
    a = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    password = Path(a.password_file).read_text(encoding="utf-8").strip()
    outbox = Outbox(a.outbox)
    uploader = MqttCloudUploader(a.device, a.host, a.port, a.ca, password, outbox.next_seq)
    sync = SyncService(outbox, uploader, min_backoff_s=1, max_backoff_s=10)
    sent = 0
    try:
        for i in range(a.repeat):
            for kind, doc_id, payload in records(datetime.now(IST), tag=f"-{i}" if a.repeat > 1 else ""):
                outbox.put(kind, doc_id, payload)
            next_pass = time.monotonic() + (a.every if i < a.repeat - 1 else 0)
            while True:
                sent += sync.step()
                if time.monotonic() >= next_pass:
                    break
                time.sleep(0.5)
            if a.repeat > 1 and (i + 1) % 10 == 0:
                st = outbox.stats()
                print(f"pass {i + 1}/{a.repeat}: sent {sent}, waiting {st['pending']}, connected {uploader.connected}", flush=True)
        deadline = time.monotonic() + a.timeout
        while outbox.stats()["pending"] and time.monotonic() < deadline:
            sent += sync.step()
            time.sleep(0.5)
    finally:
        uploader.close()
    st = outbox.stats()
    print(f"sent {sent}, pending {st['pending']}, rejected {st['dead']}" + (f", last error: {st['last_error']}" if st.get("last_error") else ""))
    if st["pending"] and not uploader.connected:
        print("Not connected: check host/port, the CA file, and that the broker knows this device's password.", file=sys.stderr)
    return 0 if st["pending"] == 0 and st["dead"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
