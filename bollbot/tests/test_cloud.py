"""Tests for the cloud rules service (Module 6)."""
import json
import tempfile
import unittest
from datetime import date, datetime, timedelta
from pathlib import Path

from bollbot.cloud.service import (InMemoryRepo, advisory_key, build_messages, reconcile,
                                   recompute_farm)
from bollbot.cloud.weather import FarmWeather, parse, request_url
from bollbot.core.config import load_etl, load_thresholds
from bollbot.core.models import Advisory, AdvisoryType, WeatherReading
from bollbot.core.rules import IST

CFG, PESTS = load_thresholds(), load_etl()
NOW = datetime(2027, 1, 18, 11, 0, tzinfo=IST)


def om_response(start, hours, prob, mm=0.0, temp=31.0, rh=55.0):
    times = [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M") for i in range(hours)]
    val = lambda v, i: v(i) if callable(v) else v
    return {"utc_offset_seconds": 19800, "timezone": "Asia/Kolkata",
            "hourly": {"time": times,
                       "precipitation_probability": [val(prob, i) for i in range(hours)],
                       "precipitation": [val(mm, i) for i in range(hours)],
                       "temperature_2m": [temp] * hours, "relative_humidity_2m": [rh] * hours}}


class WeatherTests(unittest.TestCase):
    def test_parse(self):
        start = datetime(2027, 1, 17, 0, 0)                       # local, past_days=1
        resp = om_response(start, 96, prob=lambda i: 80 if i == 50 else 10,
                           mm=lambda i: 1.5 if i in (5, 30) else 0.0)
        fw = parse(resp, NOW)
        self.assertEqual(fw.forecast[0][0], datetime(2027, 1, 18, 10, 0, tzinfo=IST))  # from now - 1 h
        self.assertEqual(max(p for _, p in fw.forecast), 80)
        self.assertEqual(fw.rain_last_24h_mm, 1.5)                # hour 5 (17 Jan 05:00) is > 24 h ago; hour 30 is not
        self.assertEqual((fw.now_reading.t_c, fw.now_reading.rh), (31.0, 55.0))
        back = FarmWeather.from_doc(json.loads(json.dumps(fw.to_doc())))
        self.assertEqual(back.forecast, fw.forecast)

    def test_bad_input(self):
        resp = om_response(datetime(2027, 1, 18), 5, 10)
        resp["hourly"]["precipitation"].pop()
        with self.assertRaisesRegex(ValueError, "length"):
            parse(resp, NOW)
        with self.assertRaisesRegex(ValueError, "aware"):
            parse(om_response(datetime(2027, 1, 18), 5, 10), NOW.replace(tzinfo=None))

    def test_url(self):
        u = request_url(11.23, 78.88)
        for part in ("latitude=11.2300", "past_days=1", "precipitation_probability", "Asia%2FKolkata"):
            self.assertIn(part, u)


def adv(typ=AdvisoryType.PEST_ETL, pest="jassid", segs=(), reason="r"):
    return Advisory("F01", typ, reason, NOW, list(segs), pest, "en text", "ta text")


class ReconcileTests(unittest.TestCase):
    def test_lifecycle(self):
        a = adv()
        r1 = reconcile({}, [a], NOW)
        key = advisory_key(a)
        self.assertEqual((list(r1.writes), r1.notify), ([key], [key]))
        existing = {key: r1.writes[key]}
        r2 = reconcile(existing, [a], NOW + timedelta(hours=1))
        self.assertEqual((r2.writes, r2.notify), ({}, []))           # unchanged: no write, no push
        r3 = reconcile(existing, [adv(reason="worse")], NOW + timedelta(hours=1))
        self.assertIn(key, r3.writes)
        self.assertEqual(r3.notify, [])                               # pest updates do not re-notify
        self.assertEqual(r3.writes[key]["created"], existing[key]["created"])
        r4 = reconcile(existing, [], NOW + timedelta(hours=2))
        self.assertFalse(r4.writes[key]["active"])
        self.assertIn("resolved_at", r4.writes[key])

    def test_pick_now_renotifies_after_cooldown(self):
        a = adv(AdvisoryType.PICK_NOW, None, ["R001-S01"])
        key = advisory_key(a)
        existing = {key: reconcile({}, [a], NOW).writes[key]}
        self.assertEqual(reconcile(existing, [a], NOW + timedelta(hours=6)).notify, [])
        r = reconcile(existing, [a], NOW + timedelta(hours=13))
        self.assertEqual(r.notify, [key])
        self.assertEqual(r.writes[key]["notified_at"], (NOW + timedelta(hours=13)).isoformat())

    def test_messages_in_users_language(self):
        doc = {**adv(AdvisoryType.PICK_NOW, None).to_dict(), "key": "k"}
        msgs = build_messages([doc], [("tokA", "ta"), ("tokB", "en")])
        self.assertEqual([m["body"] for m in msgs], ["ta text", "en text"])
        self.assertIn("மழை", msgs[0]["title"])
        self.assertEqual(msgs[1]["data"], {"key": "k", "farm": "F01", "type": "PICK_NOW"})


def scan_doc(seg, opened, closed, ts=NOW - timedelta(hours=3), weather=None):
    d = {"farm": "F01", "row": 1, "segment": seg, "ts": ts.isoformat(), "model": "m",
         "counts": {"boll_open": opened, "boll_closed": closed}}
    if weather:
        d["weather"] = weather
    return d


class RecomputeTests(unittest.TestCase):
    def setUp(self):
        self.repo = InMemoryRepo()
        self.repo.add("farms", "F01", {"lat": 11.23, "lon": 78.88})
        self.repo.add("users", "u1", {"farms": ["F01"], "lang": "ta", "fcm_tokens": ["t1"]})
        self.repo.add("users", "u2", {"farms": ["F01"], "lang": "en", "fcm_tokens": ["t2"]})
        self.repo.add("users", "u3", {"farms": ["F09"], "fcm_tokens": ["t3"]})
        self.repo.add("scans", "s1", scan_doc(1, 20, 10))
        self.repo.add("scans", "s2", scan_doc(2, 2, 30))
        self.sent, self.fetches = [], []

    def fetcher(self, prob):
        def f(lat, lon, now):
            self.fetches.append(now)
            return parse(om_response(datetime(2027, 1, 17), 96, prob), now)
        return f

    def run_at(self, now, prob=10):
        return recompute_farm(self.repo, "F01", now, CFG, PESTS, notifier=self.sent.extend,
                              fetch=self.fetcher(prob))

    def test_rain_alert_flow(self):
        self.run_at(NOW, prob=85)
        active = self.repo.advisories("F01")
        self.assertEqual([d["type"] for d in active.values()], ["PICK_NOW"])
        self.assertEqual(next(iter(active.values()))["segments"], ["R001-S01"])
        self.assertEqual(sorted(m["token"] for m in self.sent), ["t1", "t2"])   # not t3 (other farm)
        # Same data an hour later: cached weather, no new push
        self.run_at(NOW + timedelta(hours=1), prob=85)
        self.assertEqual(len(self.fetches), 1)
        self.assertEqual(len(self.sent), 2)
        # Weather cache expires; rain no longer forecast -> PICK_NOW resolved, PICK_LIST created
        self.run_at(NOW + timedelta(hours=4), prob=5)
        types = sorted(d["type"] for d in self.repo.advisories("F01").values())
        self.assertEqual(types, ["PICK_LIST"])
        st = self.repo.docs["farm_status"]["F01"]
        self.assertEqual([s["status"] for s in st["segments"]], ["READY", "NOT_READY"])

    def test_cart_weather_preferred_when_recent(self):
        self.repo.add("scans", "s3", scan_doc(3, 0, 5, ts=NOW - timedelta(minutes=30),
                                              weather={"t_c": 27.0, "rh": 88.0}))
        self.run_at(NOW)
        st = self.repo.docs["farm_status"]["F01"]
        self.assertEqual(st["weather_source"], "cart")
        self.assertEqual(st["window"]["status"], "WAIT")              # 88 % RH from the cart

    def test_pests_still_work_without_weather(self):
        def broken(lat, lon, now):
            raise OSError("no internet")
        self.repo.add("observations", "o1", {"farm": "F01", "date": "2027-01-17",
                                             "observation": "aphid_infested_plants", "count": 5, "units": 20})
        with self.assertLogs("bollbot.cloud.service", "WARNING"):
            recompute_farm(self.repo, "F01", NOW, CFG, PESTS, notifier=self.sent.extend, fetch=broken)
        types = [d["type"] for d in self.repo.advisories("F01").values()]
        self.assertIn("SPRAY_BLOCKED", types)                          # aphid ETL, segment 1 near picking
        self.assertIsNone(self.repo.docs["farm_status"]["F01"]["rain_last_24h_mm"])

    def test_malformed_and_old_docs_skipped(self):
        self.repo.add("scans", "bad", {"farm": "F01", "row": "x"})
        self.repo.add("scans", "old", scan_doc(5, 50, 0, ts=NOW - timedelta(days=30)))
        self.repo.add("traps", "bad", {"farm": "F01", "trap": "PBW-1", "date": "yesterday", "moths": 3})
        with self.assertLogs("bollbot.cloud.service", "WARNING"):
            rep = self.run_at(NOW)
        self.assertEqual([s.segment for s in rep.segments], ["R001-S01", "R001-S02"])

    def test_push_failure_does_not_lose_advice(self):
        def bad_push(msgs):
            raise RuntimeError("FCM down")
        with self.assertLogs("bollbot.cloud.service", "WARNING"):
            recompute_farm(self.repo, "F01", NOW, CFG, PESTS, notifier=bad_push, fetch=self.fetcher(90))
        self.assertTrue(self.repo.advisories("F01"))

    def test_naive_now_refused(self):
        with self.assertRaises(ValueError):
            recompute_farm(self.repo, "F01", NOW.replace(tzinfo=None), CFG, PESTS)


class LocalRunnerTests(unittest.TestCase):
    def test_runs_on_cart_outbox(self):
        from bollbot.cloud.local import main
        from bollbot.edge.store import Outbox
        with tempfile.TemporaryDirectory() as d:
            ob_path = Path(d) / "outbox.sqlite"
            ob = Outbox(ob_path)
            ob.put("scan", "a", scan_doc(1, 20, 10))
            ob.put("heartbeat", "cart01", {"x": 1})
            ob.close()
            extra = Path(d) / "extra.json"
            extra.write_text(json.dumps({"confirmations": [{"farm": "F01", "row": 1, "segment": 1,
                                                            "class": "mealybug_colony", "date": "2027-01-17"}],
                                         "observations": [{"farm": "F01", "date": "2027-01-17",
                                                           "observation": "mealybug_grade2_plants",
                                                           "count": 6, "units": 41}]}))
            from io import StringIO
            from contextlib import redirect_stdout
            buf = StringIO()
            with redirect_stdout(buf):
                rc = main(["--outbox", str(ob_path), "--farm", "F01", "--extra", str(extra),
                           "--now", NOW.isoformat()])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("R001-S01  R=0.6667  READY", out)
            self.assertIn("[SPRAY_BLOCKED]", out)                         # mealybug, but cotton ready


if __name__ == "__main__":
    unittest.main()
