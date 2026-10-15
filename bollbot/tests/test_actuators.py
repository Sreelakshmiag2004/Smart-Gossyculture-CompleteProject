"""Tests for the Pi side of the Pi <-> ESP32 link (Module 4)."""
import json
import unittest
from datetime import datetime

from bollbot.core.rules import IST
from bollbot.edge.actuators import ActuatorBridge, ServoError, SprayRefused
from bollbot.edge.store import Outbox

CFG = {"flow_ml_per_s": 10.0, "spray_min_ms": 100, "spray_max_ms": 5000, "status_max_age_s": 3}
LIMITS = [(0, 180), (20, 160), (10, 170), (30, 150)]


class FakeEsp:
    """Transport that behaves like the firmware: answers commands on publish."""

    def __init__(self):
        self.handlers, self.sent = {}, []
        self.block = "none"          # what the ESP32's safety gate says
        self.abort_after_ms = None   # simulate dead-man release mid-spray
        self.silent = False          # simulate no reply
        self.finish_moves = True
        self.motion_block = "none"   # what the ESP32's motion gate says

    def subscribe(self, topic, handler):
        self.handlers[topic] = handler

    def emit(self, suffix, payload):
        t = "cart/cart01" + suffix
        if t in self.handlers:
            self.handlers[t](t, payload if isinstance(payload, str) else json.dumps(payload))

    def publish(self, topic, payload):
        self.sent.append((topic, json.loads(payload)))
        if self.silent:
            return
        cmd = json.loads(payload)
        if topic.endswith("/cmd/spray"):
            if self.block != "none":
                self.emit("/event/spray_ack", {"id": cmd["id"], "result": "blocked", "reason": self.block})
                return
            self.emit("/event/spray_ack", {"id": cmd["id"], "result": "ok", "reason": "none"})
            ran = cmd["ms"] if self.abort_after_ms is None else self.abort_after_ms
            self.emit("/event/spray", {"id": cmd["id"], "completed": self.abort_after_ms is None,
                                       "ms_requested": cmd["ms"], "ms_on": ran,
                                       "reason": "none" if self.abort_after_ms is None else "deadman_released"})
        elif topic.endswith("/cmd/effector"):
            if cmd["on"] and self.motion_block != "none":
                self.emit("/event/effector_ack", {"id": cmd["id"], "result": "blocked", "reason": self.motion_block})
            elif cmd["on"] and not 0 < cmd["ms"] <= 10000:
                self.emit("/event/effector_ack", {"id": cmd["id"], "result": "bad_duration", "reason": "none"})
            else:
                self.emit("/event/effector_ack", {"id": cmd["id"], "result": "ok", "reason": "none"})
        elif topic.endswith("/cmd/servo"):
            angles = cmd.get("angles", [])
            ok = cmd.get("home") or (len(angles) == 4 and all(lo <= a <= hi for a, (lo, hi) in zip(angles, LIMITS)))
            self.emit("/event/servo_ack", {"id": cmd["id"], "accepted": bool(ok),
                                           "error": "" if ok else "joint outside limits"})
            if ok and self.finish_moves:
                self.emit("/event/servo_done", {"id": cmd["id"]})


def make(esp=None, outbox=None):
    esp = esp or FakeEsp()
    now = [100.0]
    b = ActuatorBridge(esp, "cart01", CFG, outbox, "F01",
                       clock=lambda: datetime(2027, 1, 18, 11, 0, tzinfo=IST), mono=lambda: now[0])
    esp.emit("/esp/online", "1")
    esp.emit("/status", {"block": "none", "deadman": True})
    return b, esp, now


class DoseTests(unittest.TestCase):
    def test_ml_to_ms(self):
        b, _, _ = make()
        self.assertEqual(b.ms_for_ml(27), 2700)       # spec: 27 ml/plant at 10 ml/s
        for bad in (0, -5, 0.5, 60):                  # 50 ms and 6000 ms are outside the pump limits
            with self.assertRaises(SprayRefused):
                b.ms_for_ml(bad)

    def test_bad_flow_config(self):
        with self.assertRaises(ValueError):
            ActuatorBridge(FakeEsp(), "cart01", {**CFG, "flow_ml_per_s": 0})


class SprayTests(unittest.TestCase):
    def setUp(self):
        self.ob = Outbox()
        self.addCleanup(self.ob.close)

    def test_completed_spray_logged(self):
        b, esp, _ = make(outbox=self.ob)
        sid = b.spray_ml(27, segment="R003-S01", purpose="mealybug_spot")
        self.assertEqual(esp.sent[-1][1], {"id": sid, "ms": 2700})
        rec = b.spray_log[-1]
        self.assertTrue(rec["completed"])
        self.assertEqual((rec["ml_requested"], rec["ml_delivered"], rec["segment"]), (27, 27.0, "R003-S01"))
        stored = [i for i in self.ob.pending() if i.kind == "spray_event"]
        self.assertEqual(stored[0].doc_id, sid)

    def test_aborted_spray_records_actual_dose(self):
        esp = FakeEsp(); esp.abort_after_ms = 900
        b, _, _ = make(esp, self.ob)
        b.spray_ml(27)
        rec = b.spray_log[-1]
        self.assertFalse(rec["completed"])
        self.assertEqual((rec["ms_on"], rec["ml_delivered"], rec["reason"]), (900, 9.0, "deadman_released"))

    def test_esp_refusal_logged(self):
        esp = FakeEsp()
        b, _, _ = make(esp, self.ob)
        esp.block = "person_side"                      # ESP32 sees a person; Pi status not yet updated
        b.spray_ml(10)
        rec = b.spray_log[-1]
        self.assertEqual((rec["result"], rec["reason"], rec["ms_on"]), ("blocked", "person_side", 0))

    def test_pi_precheck_refuses_fast(self):
        b, esp, now = make(outbox=self.ob)
        esp.emit("/status", {"block": "estop"})
        with self.assertRaisesRegex(SprayRefused, "estop"):
            b.spray_ml(10)
        self.assertFalse(any(t.endswith("/cmd/spray") for t, _ in esp.sent))   # nothing sent
        self.assertEqual(b.spray_log[-1]["result"], "refused_by_pi")
        esp.emit("/status", {"block": "none"})
        now[0] += 10                                   # status now 10 s old
        with self.assertRaisesRegex(SprayRefused, "stale"):
            b.spray_ml(10)
        esp.emit("/esp/online", "0")
        with self.assertRaisesRegex(SprayRefused, "offline"):
            b.spray_ml(10)

    def test_malformed_messages_ignored(self):
        b, esp, _ = make()
        esp.emit("/status", "not json")
        esp.emit("/event/spray", "[1,2]")
        self.assertEqual(b.status, {"block": "none", "deadman": True})
        self.assertEqual(b.spray_log, [])


class ServoTests(unittest.TestCase):
    def test_move_waits_for_done(self):
        b, esp, _ = make()
        b.move([90, 60, 120, 90], speed_dps=30)
        self.assertEqual(esp.sent[-1][1]["angles"], [90.0, 60.0, 120.0, 90.0])
        b.move(home=True)
        self.assertTrue(esp.sent[-1][1]["home"])

    def test_rejected_move_raises(self):
        b, _, _ = make()
        with self.assertRaisesRegex(ServoError, "outside limits"):
            b.move([90, 5, 90, 90])

    def test_no_reply_or_unfinished_move_raises(self):
        esp = FakeEsp(); esp.silent = True
        b, _, _ = make(esp)
        with self.assertRaisesRegex(ServoError, "no reply"):
            b.move([90, 90, 90, 90], timeout_s=0.05)
        esp.silent, esp.finish_moves = False, False
        with self.assertRaisesRegex(ServoError, "did not finish"):
            b.move([90, 90, 90, 90], timeout_s=0.05)
        self.assertEqual(b._servo, {})               # no leaked waiters


class EffectorTests(unittest.TestCase):
    def test_on_off_and_refusals(self):
        b, esp, _ = make()
        b.effector(True, 4000)
        self.assertEqual(esp.sent[-1][1]["on"], True)
        b.effector(False)
        with self.assertRaisesRegex(ServoError, "bad_duration"):
            b.effector(True, 60000)
        esp.motion_block = "deadman_released"
        with self.assertRaisesRegex(ServoError, "deadman_released"):
            b.effector(True, 3000)
        esp.silent = True
        with self.assertRaisesRegex(ServoError, "no reply"):
            b.effector(True, 3000, timeout_s=0.05)
        self.assertEqual(b._servo, {})


if __name__ == "__main__":
    unittest.main()
