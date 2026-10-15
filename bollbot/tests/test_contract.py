"""Tests for cart -> backend contract messages and the MQTT uploader (Module 7a)."""
import json
import re
import sqlite3
import tempfile
import unittest
from dataclasses import asdict
from datetime import datetime, timedelta
from pathlib import Path

from bollbot.core.rules import IST
from bollbot.edge import contract
from bollbot.edge.arm.picker import PickAttempt
from bollbot.edge.store import Outbox
from bollbot.edge.sync import MqttCloudUploader, PermanentUploadError, SyncService

ULID_RE = re.compile(r"^[0-7][0-9A-HJKMNP-TV-Z]{25}$")       # backend gossy.ids.ULID_PATTERN
T = datetime(2027, 1, 18, 10, 30, tzinfo=IST)


def scan_payload(**kw):
    p = {"scan_id": "F01-R003-S02-20270118T1030", "farm": "F01", "row": 3, "segment": 2,
         "ts": T.isoformat(), "started": (T - timedelta(minutes=2)).isoformat(),
         "counts": {"boll_closed": 41, "boll_cracking": 9, "boll_open": 27, "boll_defective": 0,
                    "flower": 0, "rosette_flower": 1, "boll_bored": 0, "mealybug_colony": 0},
         "readiness": 0.3506, "model": "yolov8n-416-v1", "frames": 120, "evidence": [],
         "source": "cart", "duration_s": 120.0, "evidence_local": ["/x.jpg"],
         "weather": {"t_c": 29.4, "rh": 100.4, "dewpoint_c": 29.4}}
    p.update(kw)
    return p


class UlidTests(unittest.TestCase):
    def test_format_and_order(self):
        a, b = contract.new_ulid(1_700_000_000_000), contract.new_ulid(1_700_000_000_001)
        self.assertRegex(a, ULID_RE)
        self.assertLess(a[:10], b[:10])                     # time-sortable
        self.assertNotEqual(contract.new_ulid(5), contract.new_ulid(5))

    def test_device_id(self):
        self.assertEqual(contract.check_device_id("cart01"), "cart01")
        for bad in ("Cart01", "c1", "svc-cart", "cart_01"):
            with self.assertRaises(ValueError):
                contract.check_device_id(bad)


class MappingTests(unittest.TestCase):
    def test_scan(self):
        topic, env = contract.envelope("scan", scan_payload(), "cart01", contract.new_ulid(), 7)
        self.assertEqual(topic, "bollbot/v1/cart01/event/scan")
        self.assertEqual(set(env), {"schema", "msgId", "deviceId", "seq", "ts", "data"})
        d = env["data"]
        self.assertEqual(d["counts"], {"bollClosed": 41, "bollCracking": 9, "bollOpen": 27, "rosetteFlower": 1})
        self.assertEqual((d["row"], d["segment"], d["frames"]), (3, 2, 120))
        self.assertEqual(d["airRhPct"], 100.0)                  # 100.4 clamped to the contract range
        self.assertNotIn("evidence_local", d)
        self.assertNotIn("readiness", d)                        # derived values are not sent

    def test_heartbeat(self):
        d = contract.data_for("heartbeat", {"ts": T.isoformat(), "fps": 4.2, "outbox": {"pending": 3},
                                            "weather": None})
        self.assertEqual(d, {"fps": 4.2, "outboxPending": 3})
        with self.assertRaises(contract.NotForCloud):
            contract.data_for("heartbeat", {"ts": T.isoformat(), "weather": None, "fps": -1})

    def test_spray(self):
        refused = contract.data_for("spray_event", {"id": "refused-1", "ms_on": 0, "completed": False,
                                                    "result": "refused_by_pi", "reason": "estop",
                                                    "ml_requested": 27, "segment": "R003-S01", "purpose": "mealybug_spot"})
        self.assertEqual(refused, {"durationMs": 0, "completed": False, "reason": "estop", "mlRequested": 27.0,
                                   "purpose": "mealybug_spot", "row": 3, "segment": 1})
        done = contract.data_for("spray_event", {"ms_on": 2700, "completed": True, "reason": "none",
                                                 "ml_delivered": 27.0, "segment": ""})
        self.assertEqual(done, {"durationMs": 2700, "completed": True, "mlDelivered": 27.0})
        with self.assertRaises(contract.NotForCloud):
            contract.data_for("spray_event", {"ms_on": 0, "completed": True})

    def test_pick(self):
        att = PickAttempt(id="p-1a2b3c4d5e", ts=T.isoformat(), farm="F01", segment="R003-S02", track_id=12,
                          conf=0.91, cam_xyz=[0.1, 0.0, 0.5], result="aborted", reason="RuntimeError: " + "x" * 400,
                          cycle_s=900.0, pitch_deg=-10.0, outcome="")
        d = contract.data_for("pick_attempt", asdict(att))
        self.assertEqual(len(d["reason"]), 256)
        self.assertNotIn("cycleS", d)                           # 900 s is outside the contract range
        self.assertNotIn("outcome", d)
        self.assertEqual((d["row"], d["segment"], d["trackId"]), (3, 2, 12))
        bad = asdict(att) | {"id": "P_1"}
        with self.assertRaises(contract.NotForCloud):
            contract.data_for("pick_attempt", bad)

    def test_unknown_kind_and_naive_time(self):
        with self.assertRaises(contract.NotForCloud):
            contract.envelope("mystery", {"ts": T.isoformat()}, "cart01", "X", 1)
        with self.assertRaises(contract.NotForCloud):
            contract.envelope("scan", scan_payload(ts="2027-01-18T10:30:00"), "cart01", "X", 1)


class OutboxIdTests(unittest.TestCase):
    def test_msg_id_stable_across_retries_new_on_replace(self):
        ob = Outbox(); self.addCleanup(ob.close)
        ob.put("scan", "a", {"v": 1}); ob.put("scan", "b", {"v": 2})
        first = ob.pending()
        self.assertTrue(all(ULID_RE.match(i.msg_id) for i in first))
        self.assertEqual([i.seq for i in first], [0, 1])
        ob.mark_failed(first[0].id, "offline")
        self.assertEqual(ob.pending()[0].msg_id, first[0].msg_id)      # retry: same msgId
        ob.put("scan", "a", {"v": 3})                                  # newer version
        again = {i.doc_id: i for i in ob.pending()}
        self.assertNotEqual(again["a"].msg_id, first[0].msg_id)
        self.assertEqual(again["a"].seq, 2)

    def test_seq_persists_and_old_files_are_upgraded(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "o.sqlite"
            db = sqlite3.connect(p)                                    # an outbox from Module 3
            db.executescript("""CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
                doc_id TEXT NOT NULL, payload TEXT NOT NULL, created REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                sent REAL, last_error TEXT, UNIQUE(kind, doc_id));
                INSERT INTO outbox(kind, doc_id, payload, created) VALUES ('scan', 'old', '{}', 0);""")
            db.commit(); db.close()
            ob = Outbox(p)
            old = ob.pending()[0]
            self.assertRegex(old.msg_id, ULID_RE)
            ob.put("scan", "new", {})
            ob.close()
            ob = Outbox(p)
            self.assertEqual(ob.next_seq(), 2)                         # 0: backfill, 1: put, 2: now
            ob.close()


class FakeInfo:
    def __init__(self, ok, mid=0): self.ok, self.mid = ok, mid
    def wait_for_publish(self, timeout=None): pass
    def is_published(self): return self.ok


class FakeClient:
    def __init__(self): self.published, self.will, self.puback, self.deny = [], None, True, None
    def will_set(self, topic, payload, qos, retain): self.will = (topic, json.loads(payload), retain)
    def connect_async(self, host, port, keepalive): self.target = (host, port)
    def loop_start(self): pass
    def loop_stop(self): pass
    def disconnect(self): pass
    def publish(self, topic, payload, qos=0, retain=False):
        self.published.append((topic, json.loads(payload), qos, retain))
        mid = len(self.published)
        if self.deny and self.deny in topic:                       # broker ACL denies: failure PUBACK
            self.on_publish(self, None, mid, FakeReason(), None)
        return FakeInfo(self.puback, mid)


class FakeReason:
    is_failure = True
    def __str__(self): return "Not authorized"


class UploaderTests(unittest.TestCase):
    def make(self):
        ob = Outbox(); self.addCleanup(ob.close)
        fc = FakeClient()
        up = MqttCloudUploader("cart01", "broker", 8883, "ca", "pw", ob.next_seq, client=fc)
        return ob, fc, up

    def test_status_will_and_online(self):
        _, fc, up = self.make()
        self.assertEqual(fc.will[0], "bollbot/v1/cart01/status")
        self.assertEqual((fc.will[1]["data"], fc.will[2]), ({"state": "offline"}, True))
        up._on_connect(fc, None, None, 0)
        topic, msg, qos, retain = fc.published[-1]
        self.assertEqual((topic, msg["data"], qos, retain), ("bollbot/v1/cart01/status", {"state": "online"}, 1, True))
        self.assertTrue(msg["ts"].endswith("+05:30"))

    def test_sync_retries_with_same_msg_id(self):
        import logging
        logging.getLogger("bollbot.edge.sync").disabled = True
        self.addCleanup(lambda: setattr(logging.getLogger("bollbot.edge.sync"), "disabled", False))
        ob, fc, up = self.make()
        ob.put("scan", "F01-R003-S02", scan_payload())
        ob.put("mystery", "x", {"ts": T.isoformat()})
        now = [0.0]
        svc = SyncService(ob, up, 5, 300, clock=lambda: now[0])
        self.assertEqual(svc.step(), 0)                                # not connected yet
        up._on_connect(fc, None, None, 0)
        fc.puback = False
        now[0] = 10; self.assertEqual(svc.step(), 0)                   # no PUBACK: retry later
        first_id = fc.published[-1][1]["msgId"]
        fc.puback = True
        now[0] = 100; self.assertEqual(svc.step(), 1)                  # scan sent; mystery dead-lettered
        sent = [m for t, m, *_ in fc.published if t.endswith("/event/scan")]
        self.assertEqual({m["msgId"] for m in sent}, {first_id})       # identical msgId on every attempt
        st = ob.stats()
        self.assertEqual((st["pending"], st["dead"]), (0, 1))

    def test_acl_denied_publish_is_kept_for_retry(self):
        import logging
        logging.getLogger("bollbot.edge.sync").disabled = True
        self.addCleanup(lambda: setattr(logging.getLogger("bollbot.edge.sync"), "disabled", False))
        ob, fc, up = self.make()
        ob.put("scan", "F01-R003-S02", scan_payload())
        up._on_connect(fc, None, None, 0)
        fc.deny = "/event/scan"
        now = [0.0]
        svc = SyncService(ob, up, 5, 300, clock=lambda: now[0])
        self.assertEqual(svc.step(), 0)
        st = ob.stats()
        self.assertEqual((st["pending"], st["dead"]), (1, 0))          # not deleted, not dead
        self.assertIn("Not authorized", st["last_error"])
        fc.deny = None
        now[0] = 1000; self.assertEqual(svc.step(), 1)                  # ACL fixed: delivered

    def test_rejects_invalid_device_id(self):
        with self.assertRaises(ValueError):
            MqttCloudUploader("Cart 01", "h", 1, "ca", "pw", lambda: 0, client=FakeClient())


if __name__ == "__main__":
    unittest.main()
