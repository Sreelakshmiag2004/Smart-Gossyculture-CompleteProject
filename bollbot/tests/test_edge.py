"""Tests for the cart software (Module 3). Camera, model and Firebase are
replaced by stand-ins; ArUco detection uses real OpenCV on synthetic frames."""
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

import cv2
import numpy as np

from bollbot.core.models import CLASSES
from bollbot.core.rules import IST
from bollbot.edge.cart import CartSession, load_cart_config
from bollbot.edge.counting import Detection, TrackCounter
from bollbot.edge.markers import ArucoReader, MarkerMap, SegmentRef, make_sheet
from bollbot.edge.segments import SegmentTracker
from bollbot.edge.sensors import FixedWeather, NoWeather
from bollbot.edge.store import Outbox
from bollbot.edge.sync import SyncService

T0 = datetime(2027, 1, 18, 10, 0, tzinfo=IST)
OPEN, CLOSED, CRACK = CLASSES.index("boll_open"), CLASSES.index("boll_closed"), CLASSES.index("boll_cracking")


def det(cls_id, tid, conf=0.9):
    return Detection(cls_id, conf, (0, 0, 10, 10), tid)


def marker_map():
    return MarkerMap({1: SegmentRef("F01", 1, 1), 2: SegmentRef("F01", 1, 2),
                      3: SegmentRef("F01", 1, 3), 9: SegmentRef("F02", 4, 1)})


def write_csv(d, text):
    p = Path(d) / "m.csv"
    p.write_text(text, encoding="utf-8")
    return p


class MarkerTests(unittest.TestCase):
    def test_load_and_validate(self):
        with tempfile.TemporaryDirectory() as d:
            m = MarkerMap.load(write_csv(d, "tag_id,farm,row,segment\n1,F01,1,1\n2,F01,1,2\n"))
            self.assertEqual(m.get(2).key, "R001-S02")
            self.assertIsNone(m.get(7))
            for bad, msg in [("tag_id,farm,row,segment\n1,F01,1,1\n1,F01,1,2\n", "used twice"),
                             ("tag_id,farm,row,segment\n1,F01,1,1\n2,F01,1,1\n", "already has tag"),
                             ("tag,farm,row\n1,F01,1\n", "columns"),
                             ("tag_id,farm,row,segment\n1,F01,0,1\n", "start at 1")]:
                with self.assertRaisesRegex(ValueError, msg):
                    MarkerMap.load(write_csv(d, bad))

    def test_reader_finds_generated_tags(self):
        d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_250)
        frame = np.full((480, 640, 3), 255, np.uint8)
        frame[50:250, 50:250] = cv2.cvtColor(cv2.aruco.generateImageMarker(d, 3, 200), cv2.COLOR_GRAY2BGR)
        frame[50:250, 350:550] = cv2.cvtColor(cv2.aruco.generateImageMarker(d, 17, 200), cv2.COLOR_GRAY2BGR)
        self.assertEqual(ArucoReader().detect(frame), [3, 17])
        self.assertEqual(ArucoReader().detect(np.full((100, 100), 255, np.uint8)), [])

    def test_printed_sheet_is_readable(self):
        with tempfile.TemporaryDirectory() as d:
            paths = make_sheet(marker_map(), d)
            self.assertEqual(len(paths), 4)
            img = cv2.imread(str(paths[0]))
            self.assertEqual(ArucoReader().detect(img), [1])


class CounterTests(unittest.TestCase):
    def test_min_hits_and_majority_class(self):
        c = TrackCounter(min_hits=3)
        for _ in range(2):
            c.update([det(OPEN, 1), det(OPEN, 2)])
        c.update([det(CRACK, 1, 0.5), det(OPEN, 3)])   # track 1: open 1.8 vs cracking 0.5
        counts = c.finalize()
        self.assertEqual(counts["boll_open"], 1)        # track 2 only 2 hits, track 3 only 1
        self.assertEqual(counts["boll_cracking"], 0)
        self.assertEqual(sum(counts.values()), 1)

    def test_boll_straddling_two_segments_counted_once(self):
        c = TrackCounter(min_hits=2)
        c.update([det(OPEN, 7)]); c.update([det(OPEN, 7)])
        self.assertEqual(c.finalize()["boll_open"], 1)
        c.update([det(OPEN, 7)]); c.update([det(OPEN, 7)]); c.update([det(OPEN, 7)])
        self.assertEqual(c.finalize()["boll_open"], 0)

    def test_low_confidence_and_untracked_ignored(self):
        c = TrackCounter(min_hits=1, min_conf=0.35)
        c.update([det(OPEN, 1, 0.2), det(OPEN, None)])
        self.assertEqual(sum(c.finalize().values()), 0)
        self.assertEqual(c.untracked, 1)


class SegmentTests(unittest.TestCase):
    def test_confirmation_and_closing(self):
        st = SegmentTracker(marker_map(), "F01", confirm_frames=2)
        self.assertIsNone(st.observe([1], T0))
        self.assertIsNone(st.observe([1], T0 + timedelta(seconds=1)))
        self.assertEqual(st.current.key, "R001-S01")
        for i in range(5):
            st.observe([], T0 + timedelta(seconds=2 + i))
        self.assertIsNone(st.observe([2], T0 + timedelta(seconds=10)))   # 1st sighting
        closed = st.observe([2], T0 + timedelta(seconds=11))
        self.assertEqual(closed.ref.key, "R001-S01")
        self.assertEqual(closed.frames, 7)
        self.assertEqual(st.current.key, "R001-S02")
        self.assertEqual(st.end(T0 + timedelta(seconds=20)).ref.key, "R001-S02")
        self.assertIsNone(st.current)

    def test_single_false_sighting_does_not_switch(self):
        st = SegmentTracker(marker_map(), "F01", confirm_frames=2)
        st.observe([1], T0); st.observe([1], T0)
        st.observe([3], T0); st.observe([], T0); st.observe([3], T0)
        self.assertEqual(st.current.key, "R001-S01")

    def test_other_farm_and_unknown_tags_ignored(self):
        st = SegmentTracker(marker_map(), "F01", confirm_frames=1)
        st.observe([9, 42], T0)
        self.assertIsNone(st.current)
        self.assertIn("farm F02", st.ignored_tags[9])
        self.assertIn("not in markers", st.ignored_tags[42])


class WeatherFallbackTests(unittest.TestCase):
    def test_missing_sensor_library_falls_back(self):
        from bollbot.edge.sensors import make_weather
        with self.assertLogs("bollbot.edge.sensors", level="WARNING"):
            w = make_weather({"weather": {"kind": "bme280"}})   # RPi.bme280 not installed here
        self.assertIsInstance(w, NoWeather)
        self.assertIsNone(w.read())


class OutboxTests(unittest.TestCase):
    def test_put_pending_sent_and_upsert(self):
        ob = Outbox(); self.addCleanup(ob.close)
        ob.put("scan", "a", {"x": 1}); ob.put("scan", "b", {"x": 2})
        items = ob.pending()
        self.assertEqual([i.doc_id for i in items], ["a", "b"])
        ob.mark_sent(items[0].id)
        ob.put("scan", "a", {"x": 3})                 # newer version -> pending again
        self.assertEqual({i.doc_id: i.payload["x"] for i in ob.pending()}, {"a": 3, "b": 2})
        self.assertEqual(ob.stats()["pending"], 2)

    def test_survives_restart(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sub" / "o.sqlite"
            ob = Outbox(p); ob.put("scan", "a", {"tamil": "பருத்தி"}); ob.close()
            ob2 = Outbox(p)
            self.assertEqual(ob2.pending()[0].payload["tamil"], "பருத்தி")
            ob2.close()

    def test_purge_sent(self):
        ob = Outbox(); self.addCleanup(ob.close)
        ob.put("scan", "a", {}, now=0); ob.mark_sent(ob.pending()[0].id, now=100)
        ob.put("scan", "b", {}, now=0)
        self.assertEqual(ob.purge_sent(50, now=200), 1)
        self.assertEqual(ob.stats(), {"pending": 1, "sent": 0, "dead": 0, "last_error": None})


class FakeUploader:
    def __init__(self, fail_times=0):
        self.fail_times, self.got = fail_times, []

    def upload(self, kind, doc_id, payload, **kw):
        if self.fail_times > 0:
            self.fail_times -= 1
            raise ConnectionError("no network")
        self.got.append(doc_id)


class SyncTests(unittest.TestCase):
    def setUp(self):
        import logging                              # expected 'upload failed' warnings
        lg = logging.getLogger("bollbot.edge.sync")
        old = lg.level
        lg.setLevel(logging.ERROR)
        self.addCleanup(lg.setLevel, old)

    def test_backoff_order_and_recovery(self):
        ob = Outbox(); self.addCleanup(ob.close)
        for k in "abc":
            ob.put("scan", k, {})
        now = [0.0]
        up = FakeUploader(fail_times=2)
        svc = SyncService(ob, up, min_backoff_s=5, max_backoff_s=300, clock=lambda: now[0])
        self.assertEqual(svc.step(), 0)                # fail 1 -> wait 5 s
        self.assertEqual(svc.step(), 0)                # still waiting, no attempt
        now[0] = 5; self.assertEqual(svc.step(), 0)    # fail 2 -> wait 10 s
        now[0] = 14; self.assertEqual(svc.step(), 0)   # too early
        now[0] = 15; self.assertEqual(svc.step(), 3)   # all sent, in order
        self.assertEqual(up.got, ["a", "b", "c"])
        self.assertEqual(svc._backoff, 5)
        self.assertEqual(ob.stats()["pending"], 0)

    def test_backoff_capped(self):
        ob = Outbox(); self.addCleanup(ob.close); ob.put("scan", "a", {})
        now = [0.0]
        svc = SyncService(ob, FakeUploader(fail_times=100), 5, 300, clock=lambda: now[0])
        for _ in range(12):
            svc.step(); now[0] += 1000
        self.assertEqual(svc._backoff, 300)
        self.assertIn("ConnectionError", ob.stats()["last_error"])


class FakeReader:
    """Marker reader driven by the frame object itself (an int index)."""

    def __init__(self, tags_by_frame):
        self.tags = tags_by_frame

    def detect(self, frame):
        return self.tags.get(frame, [])


class SessionTests(unittest.TestCase):
    cfg = load_cart_config()

    def run_walk(self, weather=None):
        saved = []
        ob = Outbox(); self.addCleanup(ob.close)
        # frames 0-1 before any marker; tag 1 at frames 2-3; tag 2 at frames 10-11
        reader = FakeReader({2: [1], 3: [1], 10: [2], 11: [2]})
        s = CartSession(self.cfg, "F01", ob, marker_map(), reader, weather or NoWeather(),
                        "yolov8n-test", save_image=lambda p, f: saved.append(p))
        dets_by_frame = {0: [det(OPEN, 99)], 1: [det(OPEN, 99)]}            # outside: ignored
        for f in range(4, 10):
            dets_by_frame[f] = [det(OPEN, 1), det(CLOSED, 2)]                 # segment 1
        for f in range(12, 16):
            dets_by_frame[f] = [det(OPEN, 3)]                                 # segment 2
        records = []
        for f in range(16):
            r = s.process(T0 + timedelta(seconds=f), f, dets_by_frame.get(f, []))
            if r:
                records.append(r)
        records.append(s.end(T0 + timedelta(seconds=20)))
        return s, ob, records, saved

    def test_walk_produces_one_scan_per_segment(self):
        s, ob, records, saved = self.run_walk(FixedWeather(31, 55))
        self.assertEqual([r["segment"] for r in records], [1, 2])
        self.assertEqual(records[0]["counts"]["boll_open"], 1)
        self.assertEqual(records[0]["counts"]["boll_closed"], 1)
        self.assertEqual(records[1]["counts"]["boll_open"], 1)
        self.assertEqual(records[0]["readiness"], 0.5)
        self.assertEqual(records[0]["weather"]["rh"], 55)
        self.assertEqual(records[0]["scan_id"], "F01-R001-S01-20270118T1000")   # minute resolution
        self.assertEqual(ob.stats()["pending"], 2)
        self.assertEqual(s.frames_outside, 3)   # frames 0-1 + frame 2 (tag seen once, not yet confirmed)
        # evidence: segment 1 lasts 6 detection frames, 1 s apart, min gap 2 s -> 3 photos max
        self.assertEqual(len(records[0]["evidence_local"]), 3)
        self.assertEqual(len(saved), 5)

    def test_heartbeat_is_one_document(self):
        s, ob, _, _ = self.run_walk()
        s.heartbeat(T0, 4.2, "cart01"); s.heartbeat(T0, 4.5, "cart01")
        hb = [i for i in ob.pending(50) if i.kind == "heartbeat"]
        self.assertEqual(len(hb), 1)
        self.assertEqual(hb[0].payload["fps"], 4.5)

    def test_photo_failure_does_not_stop_counting(self):
        def boom(p, f):
            raise OSError("disk full")
        ob = Outbox(); self.addCleanup(ob.close)
        s = CartSession(self.cfg, "F01", ob, marker_map(), FakeReader({0: [1], 1: [1]}),
                        NoWeather(), "m", save_image=boom)
        for f in range(6):
            s.process(T0 + timedelta(seconds=f), f, [det(OPEN, 5)])
        rec = s.end(T0 + timedelta(seconds=9))
        self.assertEqual(rec["counts"]["boll_open"], 1)
        self.assertEqual(rec["evidence_local"], [])

    def test_real_aruco_frames_end_to_end(self):
        d = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_250)

        def frame_with(tag=None):
            f = np.full((360, 480, 3), 200, np.uint8)
            if tag is not None:
                f[60:260, 140:340] = cv2.cvtColor(cv2.aruco.generateImageMarker(d, tag, 200),
                                                  cv2.COLOR_GRAY2BGR)
            return f
        ob = Outbox(); self.addCleanup(ob.close)
        s = CartSession(self.cfg, "F01", ob, marker_map(), ArucoReader(), NoWeather(), "m",
                        save_image=lambda p, f: None)
        seq = [frame_with(1), frame_with(1)] + [frame_with()] * 4 + [frame_with(2), frame_with(2)]
        recs = [s.process(T0 + timedelta(seconds=i), fr, [det(OPEN, 1)] if 2 <= i < 6 else [])
                for i, fr in enumerate(seq)]
        closed = [r for r in recs if r]
        self.assertEqual(len(closed), 1)
        self.assertEqual(closed[0]["counts"]["boll_open"], 1)
        self.assertEqual(s.segments.current.key, "R001-S02")


if __name__ == "__main__":
    unittest.main()
