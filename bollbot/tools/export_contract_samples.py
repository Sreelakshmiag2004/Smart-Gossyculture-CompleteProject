"""Write sample MQTT messages produced by the REAL cart code, for the backend's
contract test (backend/tests/unit/test_cart_samples.py).

  python -m bollbot.tools.export_contract_samples > backend/tests/fixtures/cart_samples.json

Run again whenever the cart's message conversion or the contract changes.
"""
from __future__ import annotations

import json
import sys
from dataclasses import asdict
from datetime import datetime, timedelta

from bollbot.core.models import CLASSES
from bollbot.core.rules import IST
from bollbot.edge import contract
from bollbot.edge.actuators import ActuatorBridge
from bollbot.edge.arm.picker import PickAttempt
from bollbot.edge.cart import CartSession, load_cart_config
from bollbot.edge.counting import Detection
from bollbot.edge.markers import MarkerMap, SegmentRef
from bollbot.edge.sensors import FixedWeather, NoWeather
from bollbot.edge.store import Outbox

T0 = datetime(2026, 9, 29, 10, 0, tzinfo=IST)     # within the backend tests' clock window


class _Reader:
    def __init__(self, tags): self.tags = tags
    def detect(self, frame): return self.tags.get(frame, [])


class _Transport:
    def __init__(self): self.h = {}
    def subscribe(self, t, f): self.h[t] = f
    def emit(self, suffix, d): self.h["cart/cart01" + suffix]("t", d if isinstance(d, str) else json.dumps(d))
    def publish(self, topic, payload):
        cmd = json.loads(payload)
        self.emit("/event/spray_ack", {"id": cmd["id"], "result": "ok", "reason": "none"})
        self.emit("/event/spray", {"id": cmd["id"], "completed": False, "ms_requested": cmd["ms"],
                                   "ms_on": 900, "reason": "deadman_released"})


def records() -> list[tuple[str, dict]]:
    out: list[tuple[str, dict]] = []
    ob = Outbox()
    mm = MarkerMap({1: SegmentRef("F01", 3, 1), 2: SegmentRef("F01", 3, 2)})
    open_id, closed_id = CLASSES.index("boll_open"), CLASSES.index("boll_closed")
    s = CartSession(load_cart_config(), "F01", ob, mm, _Reader({0: [1], 1: [1], 9: [2], 10: [2]}),
                    FixedWeather(30.2, 101.0), "yolov8n-416-v1", save_image=lambda p, f: None)
    for f in range(12):
        dets = [Detection(open_id, 0.9, (0, 0, 9, 9), 1), Detection(closed_id, 0.8, (0, 0, 9, 9), 2)] if 2 <= f < 9 else []
        s.process(T0 + timedelta(seconds=f), f, dets)
    s.end(T0 + timedelta(seconds=15))
    s.weather = NoWeather()
    s.heartbeat(T0 + timedelta(seconds=16), 4.2, "cart01")
    tr = _Transport()
    b = ActuatorBridge(tr, "cart01", {"flow_ml_per_s": 10, "spray_min_ms": 100, "spray_max_ms": 5000},
                       ob, "F01", clock=lambda: T0 + timedelta(seconds=20))
    tr.emit("/esp/online", "1")
    tr.emit("/status", {"block": "none"})
    b.spray_ml(27, segment="R003-S01", purpose="mealybug_spot")
    tr.emit("/status", {"block": "estop"})
    try:
        b.spray_ml(10)
    except Exception:
        pass
    for att in (PickAttempt(id="p-0a1b2c3d4e", ts=(T0 + timedelta(seconds=30)).isoformat(), farm="F01",
                            segment="R003-S02", track_id=7, conf=0.88, cam_xyz=[0.1, 0.0, 0.5],
                            base_xyz=[0.33, 0.0, 0.15], pitch_deg=0.0, result="completed", cycle_s=14.2,
                            outcome="picked", lint_left_g=0.4, trash_g=0.1),
                PickAttempt(id="p-0a1b2c3d4f", ts=(T0 + timedelta(seconds=40)).isoformat(), farm="F01",
                            segment="R003-S02", track_id=8, conf=0.71, cam_xyz=None, result="unreachable",
                            reason="joint limits: elbow 187.8 not in [10.0, 170.0]")):
        ob.put("pick_attempt", att.id, asdict(att))
    for item in ob.pending(100):
        out.append((item.kind, item))
    ob.close()
    return out


def samples() -> list[dict]:
    res = []
    for kind, item in records():
        topic, env = contract.envelope(kind, item.payload, "cart01", item.msg_id, item.seq)
        res.append({"source": kind, "topic": topic, "envelope": env})
    return res


if __name__ == "__main__":
    json.dump(samples(), sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")
