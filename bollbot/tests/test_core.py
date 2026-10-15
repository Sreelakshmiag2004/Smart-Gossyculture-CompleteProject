"""Unit tests for the decision engine (Module 1).

Run from the folder that contains bollbot/:
    python -m unittest discover -s bollbot/tests -t .
or, if pytest is installed:
    pytest bollbot/tests
"""
import tempfile
import unittest
from datetime import date, datetime, timedelta
from pathlib import Path

from bollbot.core import rules
from bollbot.core.config import load_etl, load_thresholds
from bollbot.core.engine import run_farm
from bollbot.core.etl import (EtlInputs, evaluate, longest_run_at_or_above,
                              nightly_trap_means)
from bollbot.core.models import (AdvisoryType, ConfirmedDetection, ManualObservation,
                                 ReadinessStatus, SegmentScan, TrapCount,
                                 WeatherReading, WindowStatus)

CFG = load_thresholds()
PESTS = load_etl()
NOW = datetime(2027, 1, 18, 11, 0)


def scan(row=12, seg=4, closed=0, cracking=0, opened=0, ts=NOW, farm="F03", **extra):
    counts = {"boll_closed": closed, "boll_cracking": cracking, "boll_open": opened}
    counts.update(extra)
    return SegmentScan(farm=farm, row=row, segment=seg, ts=ts, counts=counts,
                       model="yolov8n-416-test")


class ReadinessTests(unittest.TestCase):
    def test_formula(self):
        self.assertEqual(rules.readiness({"boll_closed": 41, "boll_cracking": 9,
                                          "boll_open": 27}), 27 / 77)   # unrounded

    def test_no_bolls_is_none(self):
        self.assertIsNone(rules.readiness({"flower": 5}))
        self.assertEqual(rules.readiness_status(None, CFG), ReadinessStatus.NO_DATA)

    def test_status_bands(self):
        self.assertEqual(rules.readiness_status(0.40, CFG), ReadinessStatus.READY)
        self.assertEqual(rules.readiness_status(0.39, CFG), ReadinessStatus.BUILDING)
        self.assertEqual(rules.readiness_status(0.20, CFG), ReadinessStatus.BUILDING)
        self.assertEqual(rules.readiness_status(0.19, CFG), ReadinessStatus.NOT_READY)

    def test_latest_scan_wins(self):
        old = scan(opened=50, closed=0, ts=NOW - timedelta(days=7))
        new = scan(opened=1, closed=9, ts=NOW)
        latest = rules.latest_by_segment([new, old])
        self.assertIs(latest["R012-S04"], new)

    def test_ranking_by_open_bolls(self):
        a = scan(seg=1, opened=10, closed=5)
        b = scan(seg=2, opened=30, closed=10)
        c = scan(seg=3, opened=2, closed=20)   # not ready
        ranked = rules.rank_segments([a, b, c], 0.40)
        self.assertEqual([s.segment_key for s in ranked], ["R012-S02", "R012-S01"])


class WindowTests(unittest.TestCase):
    def test_dew_point_reference(self):
        # 30 C at 60% RH -> dew point about 21.4 C (standard psychrometric value)
        self.assertAlmostEqual(rules.dew_point_c(30, 60), 21.4, delta=0.2)
        # Saturated air: dew point equals air temperature
        self.assertAlmostEqual(rules.dew_point_c(25, 100), 25.0, delta=0.01)

    def test_dew_point_rejects_bad_rh(self):
        with self.assertRaises(ValueError):
            rules.dew_point_c(30, 0)

    def test_safe_window(self):
        r = rules.picking_window(WeatherReading(32, 50), NOW, 0.0, CFG)
        self.assertEqual(r.status, WindowStatus.SAFE, r.failed)

    def test_each_condition_fails(self):
        early = NOW.replace(hour=8)
        self.assertEqual(rules.picking_window(WeatherReading(32, 50), early, 0, CFG).status,
                         WindowStatus.WAIT)
        humid = rules.picking_window(WeatherReading(28, 85), NOW, 0, CFG)
        self.assertEqual(humid.status, WindowStatus.WAIT)
        self.assertTrue(any("RH" in f for f in humid.failed))
        rained = rules.picking_window(WeatherReading(32, 50), NOW, 5.0, CFG)
        self.assertTrue(any("rain" in f for f in rained.failed))


class RainAlertTests(unittest.TestCase):
    ready = [scan(seg=1, opened=20, closed=10), scan(seg=2, opened=5, closed=30)]

    def test_alert_fires(self):
        fc = [(NOW + timedelta(hours=20), 72.0)]
        adv = rules.rain_alert("F03", self.ready, fc, NOW, CFG)
        self.assertEqual(adv.type, AdvisoryType.PICK_NOW)
        self.assertEqual(adv.segments, ["R012-S01"])  # seg 2 has R = 0.14

    def test_low_probability_no_alert(self):
        fc = [(NOW + timedelta(hours=20), 40.0)]
        self.assertIsNone(rules.rain_alert("F03", self.ready, fc, NOW, CFG))

    def test_rain_beyond_horizon_ignored(self):
        fc = [(NOW + timedelta(hours=60), 95.0)]
        self.assertIsNone(rules.rain_alert("F03", self.ready, fc, NOW, CFG))

    def test_no_open_cotton_no_alert(self):
        fc = [(NOW + timedelta(hours=5), 95.0)]
        self.assertIsNone(rules.rain_alert("F03", [scan(closed=40)], fc, NOW, CFG))


class MoistureTests(unittest.TestCase):
    def test_wet_basis(self):
        self.assertEqual(rules.wet_basis_moisture(15.0, 13.8), 8.0)

    def test_classes(self):
        self.assertEqual(rules.moisture_class(7.9, CFG), "SAFE")
        self.assertEqual(rules.moisture_class(10, CFG), "DRY_AND_PICK")
        self.assertEqual(rules.moisture_class(12.5, CFG), "TOO_WET")

    def test_bad_weights(self):
        with self.assertRaises(ValueError):
            rules.wet_basis_moisture(10, 11)


class EtlTests(unittest.TestCase):
    def trap(self, d, moths, trap="PBW-1"):
        return TrapCount("F03", trap, d, moths)

    def test_nightly_means_across_traps(self):
        d = date(2027, 1, 10)
        means = nightly_trap_means([self.trap(d, 6), self.trap(d, 10, "PBW-2"),
                                    self.trap(d, 99, "WF-1")], "PBW")
        self.assertEqual(means, {d: 8.0})

    def test_run_must_be_consecutive(self):
        d0 = date(2027, 1, 10)
        means = {d0: 9, d0 + timedelta(1): 9, d0 + timedelta(3): 9}  # gap on day 2
        self.assertEqual(longest_run_at_or_above(means, 8), 2)
        means[d0 + timedelta(2)] = 9
        self.assertEqual(longest_run_at_or_above(means, 8), 4)

    def test_pbw_trap_rule(self):
        d0 = date(2027, 1, 14)
        traps = [self.trap(d0 + timedelta(i), m) for i, m in enumerate([9, 8, 12])]
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(traps=traps))}
        self.assertTrue(f["pink_bollworm_trap"].crossed)

    def test_insufficient_trap_data(self):
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(traps=[self.trap(date(2027, 1, 1), 20)]))}
        self.assertTrue(f["pink_bollworm_trap"].insufficient)
        self.assertFalse(f["pink_bollworm_trap"].crossed)

    def test_rosette_flower_ratio(self):
        small = [scan(flower=5, rosette_flower=3)]
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(scans=small))}
        self.assertTrue(f["pink_bollworm_flowers"].insufficient)
        big = [scan(flower=54, rosette_flower=6)]        # 6/60 = 10% -> CICR ETL
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(scans=big))}
        self.assertTrue(f["pink_bollworm_flowers"].crossed)
        self.assertEqual(f["pink_bollworm_flowers"].segments, ["R012-S04"])

    def test_green_boll_ratio_ignores_open_bolls(self):
        # 5 bored of 50 green bolls = 10% -> crossed, however many open bolls exist.
        s = [scan(closed=40, cracking=5, boll_bored=5, opened=500)]
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(scans=s))}
        self.assertTrue(f["pink_bollworm_green_bolls"].crossed)
        self.assertEqual(f["pink_bollworm_green_bolls"].value, 0.1)

    def test_per_leaf_uses_latest_date(self):
        old = ManualObservation("F03", date(2027, 1, 10), "thrips_per_leaf", 900, 25)
        new = ManualObservation("F03", date(2027, 1, 17), "thrips_per_leaf", 75, 25)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[old, new]))}
        self.assertFalse(f["thrips"].crossed)              # 3/leaf, latest date only
        self.assertEqual(f["thrips"].value, 3.0)

    def test_strict_more_than(self):
        # AESA-2014: 'more than 2 jassids per leaf' -> exactly 2.0 is NOT crossed
        at = ManualObservation("F03", date(2027, 1, 17), "jassid_per_leaf", 50, 25)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[at]))}
        self.assertFalse(f["jassid"].crossed)
        above = ManualObservation("F03", date(2027, 1, 17), "jassid_per_leaf", 51, 25)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[above]))}
        self.assertTrue(f["jassid"].crossed)

    def test_whitefly_percent_of_plants(self):
        half = ManualObservation("F03", date(2027, 1, 17), "whitefly_plants_over_10", 10, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[half]))}
        self.assertTrue(f["whitefly"].crossed)             # 2 of 4 = 50% counts
        few = ManualObservation("F03", date(2027, 1, 17), "whitefly_plants_over_10", 9, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[few]))}
        self.assertFalse(f["whitefly"].crossed)
        small = ManualObservation("F03", date(2027, 1, 17), "whitefly_plants_over_10", 4, 4)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[small]))}
        self.assertTrue(f["whitefly"].insufficient)

    def test_thrips_threshold(self):
        obs = ManualObservation("F03", date(2027, 1, 17), "thrips_per_leaf", 275, 25)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[obs]))}
        self.assertTrue(f["thrips"].crossed)               # 11/leaf > 10

    def test_percent_units(self):
        obs = ManualObservation("F03", date(2027, 1, 17), "aphid_infested_plants", 3, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[obs]))}
        self.assertTrue(f["aphid"].crossed)   # 15% > 10%
        exact = ManualObservation("F03", date(2027, 1, 17), "aphid_infested_plants", 2, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[exact]))}
        self.assertFalse(f["aphid"].crossed)  # exactly 10% is not 'more than'

    def test_trap_strict_flag(self):
        means = {date(2027, 1, 1): 8, date(2027, 1, 2): 8, date(2027, 1, 3): 8}
        self.assertEqual(longest_run_at_or_above(means, 8), 3)
        self.assertEqual(longest_run_at_or_above(means, 8, strict=True), 0)

    def test_mealybug_needs_grade2_threshold(self):
        c = ConfirmedDetection("F03", 12, 4, "mealybug_colony", date(2027, 1, 17))
        # Camera detections and a confirmed colony alone never trigger treatment.
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(scans=[scan(mealybug_colony=4)],
                                                          confirmed=[c]))}
        self.assertFalse(f["mealybug"].crossed)
        self.assertTrue(f["mealybug"].insufficient)
        # 4 of 41 sampled plants at grade 2 = 9.8% < 10%
        low = ManualObservation("F03", date(2027, 1, 17), "mealybug_grade2_plants", 4, 41)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[low], confirmed=[c]))}
        self.assertFalse(f["mealybug"].crossed)
        # 5 of 41 = 12.2% -> crossed; confirmed detections give the location
        high = ManualObservation("F03", date(2027, 1, 17), "mealybug_grade2_plants", 5, 41)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[high], confirmed=[c]))}
        self.assertTrue(f["mealybug"].crossed)
        self.assertEqual(f["mealybug"].segments, ["R012-S04"])

    def test_bollworm_larvae_per_plant(self):
        obs = ManualObservation("F03", date(2027, 1, 17), "bollworm_larvae_per_plant", 22, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[obs]))}
        self.assertTrue(f["bollworm_larvae"].crossed)

    def test_bollworm_squares_more_than_3(self):
        at = ManualObservation("F03", date(2027, 1, 17), "bollworm_damaged_squares_per_plant", 60, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[at]))}
        self.assertFalse(f["bollworm_squares"].crossed)    # exactly 3/plant
        above = ManualObservation("F03", date(2027, 1, 17), "bollworm_damaged_squares_per_plant", 70, 20)
        f = {x.pest: x for x in evaluate(PESTS, EtlInputs(manual=[above]))}
        self.assertTrue(f["bollworm_squares"].crossed)


class EngineTests(unittest.TestCase):
    confirmed = [ConfirmedDetection("F03", 3, 1, "mealybug_colony", date(2027, 1, 17))]
    grade2 = [ManualObservation("F03", date(2027, 1, 17), "mealybug_grade2_plants", 6, 41)]

    def test_spot_treat_when_not_near_picking(self):
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[scan(closed=40, opened=2)],
                       confirmed=self.confirmed, manual=self.grade2)
        types = [a.type for a in rep.advisories]
        self.assertIn(AdvisoryType.SPOT_TREAT, types)
        adv = next(a for a in rep.advisories if a.type == AdvisoryType.SPOT_TREAT)
        self.assertEqual(adv.segments, ["R003-S01"])
        self.assertIn("மாவுப்பூச்சி", adv.text_ta)
        self.assertIn("CIB&RC", adv.text_en)
        self.assertIn("Never spray the whole field", adv.text_en)

    def test_spray_blocked_when_picking_close(self):
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[scan(closed=10, opened=20)],
                       confirmed=self.confirmed, manual=self.grade2)
        types = [a.type for a in rep.advisories]
        self.assertIn(AdvisoryType.SPRAY_BLOCKED, types)
        self.assertNotIn(AdvisoryType.SPOT_TREAT, types)

    def test_virus_is_alert_only_even_when_blocked(self):
        obs = ManualObservation("F03", date(2027, 1, 17), "leaf_curl_plants", 2, 50)
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[scan(closed=10, opened=20)], manual=[obs])
        self.assertIn(AdvisoryType.PEST_ALERT, [a.type for a in rep.advisories])

    def test_pick_now_replaces_pick_list(self):
        fc = [(NOW + timedelta(hours=10), 80.0)]
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[scan(closed=10, opened=20)], forecast=fc)
        types = [a.type for a in rep.advisories]
        self.assertIn(AdvisoryType.PICK_NOW, types)
        self.assertNotIn(AdvisoryType.PICK_LIST, types)

    def test_other_farms_and_old_evidence_ignored(self):
        old = ConfirmedDetection("F03", 3, 1, "mealybug_colony", date(2026, 12, 1))
        other = ConfirmedDetection("F09", 3, 1, "mealybug_colony", date(2027, 1, 17))
        old_obs = ManualObservation("F03", date(2026, 12, 1), "mealybug_grade2_plants", 20, 41)
        other_obs = ManualObservation("F09", date(2027, 1, 17), "mealybug_grade2_plants", 20, 41)
        rep = run_farm("F03", NOW, CFG, PESTS, scans=[scan(farm="F09", opened=50)],
                       confirmed=[old, other], manual=[old_obs, other_obs])
        self.assertEqual(rep.advisories, [])
        self.assertEqual(rep.segments, [])

    def test_window_reported(self):
        rep = run_farm("F03", NOW, CFG, PESTS, weather_now=WeatherReading(31, 55))
        self.assertEqual(rep.window.status, WindowStatus.SAFE)


class ModelTests(unittest.TestCase):
    def test_round_trip_matches_spec_schema(self):
        s = scan(closed=41, cracking=9, opened=27, boll_defective=2)
        s.weather = WeatherReading(29.4, 63.0, 21.6)
        d = s.to_dict()
        self.assertEqual(d["scan_id"], "F03-R012-S04-20270118T1100")
        self.assertEqual(len(d["counts"]), 8)
        self.assertAlmostEqual(d["readiness"], 0.3506, places=4)
        back = SegmentScan.from_dict(d)
        self.assertEqual(back.counts, s.counts)
        self.assertEqual(back.ts, s.ts)

    def test_unknown_class_rejected(self):
        with self.assertRaises(ValueError):
            scan(aphid=3)


class ConfigTests(unittest.TestCase):
    def test_bad_thresholds_rejected(self):
        bad = ("readiness: {ready_min: 0.2, building_min: 0.4}\n"
               "picking_window: {}\nrain_alert: {}\nspray_block: {}\n")
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "t.yaml"
            p.write_text(bad)
            with self.assertRaises(ValueError):
                load_thresholds(p)

    def test_bad_etl_action_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "e.yaml"
            p.write_text("pests:\n  x: {type: presence, threshold: 1, action: SPRAY_ALL}\n")
            with self.assertRaises(ValueError):
                load_etl(p)


if __name__ == "__main__":
    unittest.main()
