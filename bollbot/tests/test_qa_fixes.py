"""Regression tests: one per bug in the QA report of 14 Oct 2026.
Each test reproduces the report's scenario and checks the fixed behaviour."""
import sys
import tempfile
import types
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

from bollbot.core import rules
from bollbot.core.config import load_etl, load_thresholds
from bollbot.core.engine import run_farm
from bollbot.core.etl import EtlInputs, evaluate
from bollbot.core.messages import fill_text
from bollbot.core.models import (Advisory, AdvisoryType, ManualObservation, SegmentScan,
                                 TrapCount, WeatherReading, WindowStatus)
from bollbot.ml import train
from bollbot.ml.dataset import validate
from bollbot.ml.evaluate import extract_metrics
from bollbot.ml.metrics import check_targets
from bollbot.ml.split import SplitError, build
from bollbot.tests.test_ml import make_farm, make_image

CFG = load_thresholds()
PESTS = load_etl()
NOW = datetime(2027, 1, 18, 11, 30)


def scan(seg=4, ts=NOW, **counts):
    return SegmentScan(farm="F03", row=12, segment=seg, ts=ts, counts=counts, model="t")


class Bug01SplitRerun(unittest.TestCase):
    def test_rerun_into_same_folder_is_refused_then_clean_with_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            raw, out = Path(d) / "raw", Path(d) / "ds"
            for i, f in enumerate(["F01", "F02", "F03", "F04"]):
                make_farm(raw, f, 2, 100 * i)
            build(raw, out, {"train": ["F01", "F02"], "val": ["F03"], "test": ["F04"]})
            swapped = {"train": ["F04", "F02"], "val": ["F03"], "test": ["F01"]}
            with self.assertRaisesRegex(SplitError, "already contains a split"):
                build(raw, out, swapped)
            m = build(raw, out, swapped, overwrite=True)
            on_disk = {s: sorted(p.name.split("__")[0] for p in (out / "images" / s).iterdir())
                       for s in ("train", "val", "test")}
            self.assertEqual(on_disk["test"], ["F01", "F01"])            # F04 gone from test
            self.assertNotIn("F01", on_disk["train"])                     # no leak
            self.assertEqual(m["splits"]["train"]["images"], len(on_disk["train"]))


class Bug02Timezones(unittest.TestCase):
    def test_utc_instant_is_judged_in_ist(self):
        ist_now = NOW.replace(tzinfo=rules.IST)                         # 11:30 IST
        utc_now = ist_now.astimezone(timezone.utc)                      # 06:00 UTC
        w = WeatherReading(32, 50)
        self.assertEqual(rules.picking_window(w, ist_now, 0, CFG).status, WindowStatus.SAFE)
        self.assertEqual(rules.picking_window(w, utc_now, 0, CFG).status, WindowStatus.SAFE)

    def test_mixed_naive_and_aware_refused(self):
        aware_now = NOW.replace(tzinfo=rules.IST)
        with self.assertRaisesRegex(ValueError, "mixed naive"):
            run_farm("F03", aware_now, CFG, PESTS, scans=[scan(boll_open=5)])

    def test_trap_dates_use_ist_calendar_day(self):
        # 20:00 UTC on 17 Jan = 01:30 IST on 18 Jan: a trap dated 18 Jan is 'today'.
        utc_now = datetime(2027, 1, 17, 20, 0, tzinfo=timezone.utc)
        traps = [TrapCount("F03", "PBW-1", date(2027, 1, d), 12) for d in (16, 17, 18)]
        rep = run_farm("F03", utc_now, CFG, PESTS, traps=traps)
        f = {x.pest: x for x in rep.findings}
        self.assertTrue(f["pink_bollworm_trap"].crossed)


class Bug03CameraRatioRescans(unittest.TestCase):
    def test_rescanning_does_not_inflate_sample(self):
        scans = [scan(ts=NOW - timedelta(hours=h), flower=8, rosette_flower=2) for h in range(5)]
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(scans=scans))}
        self.assertTrue(f["pink_bollworm_flowers"].insufficient)        # 10 flowers, not 50
        self.assertFalse(f["pink_bollworm_flowers"].crossed)


class Bug04TrainRunName(unittest.TestCase):
    def test_existing_run_name_refused_before_training(self):
        fake = types.ModuleType("ultralytics")
        fake.__version__ = "test"
        fake.YOLO = lambda *a, **k: self.fail("training must not start")
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "runs" / "v1").mkdir(parents=True)
            old = sys.modules.get("ultralytics")
            sys.modules["ultralytics"] = fake
            try:
                rc = train.main([str(Path(d) / "data.yaml"), "--name", "v1",
                                 "--project", str(Path(d) / "runs")])
            finally:
                if old is None:
                    del sys.modules["ultralytics"]
                else:
                    sys.modules["ultralytics"] = old
            self.assertEqual(rc, 1)


class Bug05HumidityOver100(unittest.TestCase):
    def test_saturated_sensor_reading_accepted(self):
        self.assertAlmostEqual(rules.dew_point_c(25, 100.4), 25.0, places=2)
        rep = run_farm("F03", NOW, CFG, PESTS, weather_now=WeatherReading(25, 100.4))
        self.assertEqual(rep.window.status, WindowStatus.WAIT)
        with self.assertRaises(ValueError):
            rules.dew_point_c(25, 110)                                  # still a real fault


class Bug06FutureData(unittest.TestCase):
    def test_scans_and_records_after_now_ignored(self):
        future = scan(ts=NOW + timedelta(days=3), boll_open=90, boll_closed=10)
        past = scan(ts=NOW - timedelta(days=1), boll_open=1, boll_closed=30)
        obs = ManualObservation("F03", date(2027, 1, 20), "aphid_infested_plants", 20, 20)
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[future, past], manual=[obs])
        self.assertEqual(rep.segments[0].open_bolls, 1)
        self.assertEqual(rep.advisories, [])


class Bug07EmptyLocations(unittest.TestCase):
    def test_spot_treat_without_confirmed_location(self):
        obs = ManualObservation("F03", date(2027, 1, 17), "mealybug_grade2_plants", 10, 41)
        rep = run_farm("F03", NOW, CFG, PESTS, manual=[obs])
        adv = next(a for a in rep.advisories if a.type == AdvisoryType.SPOT_TREAT)
        self.assertIn("not yet marked", adv.text_en)
        self.assertNotIn("Locations: .", adv.text_en)
        self.assertIn("குறிக்கப்படவில்லை", adv.text_ta)


class Bug08SameStem(unittest.TestCase):
    def test_two_images_one_stem_is_error(self):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d)
            make_farm(raw, "F01", 1, 0)
            make_image(raw / "F01" / "images" / "F01_000.png", 77)
            rep = validate(raw)
            self.assertTrue(any("share this name" in i.message for i in rep.errors))


class Bug09HiddenFolders(unittest.TestCase):
    def test_hidden_folder_is_not_a_farm(self):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d)
            make_farm(raw, "F01", 1, 0)
            (raw / ".ipynb_checkpoints").mkdir()
            rep = validate(raw)
            self.assertTrue(rep.ok)
            self.assertEqual([f.farm for f in rep.farms], ["F01"])


class Bug10ConfigValidation(unittest.TestCase):
    def check_rejected(self, rule_yaml, msg):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "e.yaml"
            p.write_text("pests:\n  x: " + rule_yaml + "\n")
            with self.assertRaisesRegex(ValueError, msg):
                load_etl(p)

    def test_bad_configs(self):
        base = "{type: mean_per_unit, observation: o, threshold: 2, action: ADVISORY"
        self.check_rejected(base + ", min_units: 0}", "min_units")
        self.check_rejected(base + ", stict: true}", "unknown keys")
        self.check_rejected(base + ", strict: yes please}", "strict")
        self.check_rejected("{type: consecutive_nights, trap_prefix: PBW, threshold: 8, "
                            "action: ADVISORY}", "nights")
        self.check_rejected("{type: camera_ratio, numerator: [aphid], denominator: [flower], "
                            "threshold: 0.1, action: ADVISORY}", "unknown classes")


class Bug11TrapMessage(unittest.TestCase):
    def test_strict_rule_says_more_than(self):
        rules_ = {"t": {**PESTS["pink_bollworm_trap"], "strict": True}}
        traps = [TrapCount("F03", "PBW-1", date(2027, 1, d), 9) for d in (14, 15, 16)]
        f = evaluate(rules_, EtlInputs(traps=traps))[0]
        self.assertIn("> 8", f.detail)
        self.assertNotIn(">=", f.detail)


class Bug12UnroundedThreshold(unittest.TestCase):
    def test_ratio_just_below_threshold_not_rounded_up(self):
        s = scan(boll_open=11999, boll_closed=28001)                     # 0.299975
        self.assertFalse(rules.spray_blocked([s], CFG))
        self.assertEqual(s.to_dict()["readiness"], 0.3)                  # rounded for display only


class Bug13ZuluTimestamps(unittest.TestCase):
    def test_trailing_z_parsed(self):
        d = scan(boll_open=1).to_dict()
        d["ts"] = "2027-01-18T06:00:00Z"
        s = SegmentScan.from_dict(d)
        self.assertEqual(s.ts, datetime(2027, 1, 18, 6, 0, tzinfo=timezone.utc))


class Bug14EvaluationClasses(unittest.TestCase):
    def fake(self, names):
        return SimpleNamespace(
            names=names, ap_class_index=[0],
            box=SimpleNamespace(p=[1.0], r=[1.0], ap50=[1.0], ap=[1.0],
                                map50=1.0, map=1.0, mp=1.0, mr=1.0),
            confusion_matrix=SimpleNamespace(matrix=[[1, 0], [0, 0]]))

    def test_class_order_mismatch_raises(self):
        with self.assertRaisesRegex(ValueError, "differ"):
            extract_metrics(self.fake({0: "b", 1: "a"}), ["a", "b"])

    def test_missing_open_boll_class_fails_target(self):
        res = check_targets({"map50": 0.9, "per_class": {"boll_closed": {"recall": 0.9}}},
                            {"map50_min": 0.8, "open_boll_recall_min": 0.85,
                             "fps_min": 3, "count_mape_max_pct": 15})
        r = next(x for x in res if x.kpi == "boll_open recall")
        self.assertFalse(r.met)


class Bug15RainHoursInText(unittest.TestCase):
    def test_hours_follow_config(self):
        adv = Advisory("F03", AdvisoryType.PICK_NOW, "r", NOW, ["R012-S04"])
        fill_text(adv, hours=24)
        self.assertIn("24 hours", adv.text_en)
        self.assertIn("24 மணி", adv.text_ta)
        self.assertNotIn("48", adv.text_en)


class RainLimitConvention(unittest.TestCase):
    def test_limits_are_allowed_values(self):
        w = WeatherReading(32, 75.0)                                     # exactly max RH
        self.assertEqual(rules.picking_window(w, NOW, 2.0, CFG).status, WindowStatus.SAFE)
        self.assertEqual(rules.picking_window(w, NOW, 2.1, CFG).status, WindowStatus.WAIT)


if __name__ == "__main__":
    unittest.main()
