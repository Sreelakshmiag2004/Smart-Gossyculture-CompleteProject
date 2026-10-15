"""Module 8: experiment analyses on synthetic data with known answers."""
import json
import shutil
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from bollbot.analysis import common
from bollbot.analysis.common import DataError, cohen_kappa, percentile, wilson
from bollbot.analysis.e1_e2_e3 import e1, e2, e3
from bollbot.analysis.e4_e5 import e4, e5
from bollbot.analysis.e6_e7 import card_deposit_pct, e6, e7
from bollbot.analysis.e8_to_e11 import e8, e9, e10, e11, sus_score
from bollbot.analysis.report import run_all, to_markdown
from bollbot.core.rules import IST
from bollbot.edge.store import Outbox

REPO_E6 = Path(common.EXPERIMENTS_DIR) / "E6"


class TempDir(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.d = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def write(self, name, text):
        p = self.d / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        return p


class StatisticsTests(unittest.TestCase):
    def test_helpers(self):
        self.assertAlmostEqual(cohen_kappa([(True, True), (False, False), (True, False), (False, False)]), 0.5)
        self.assertIsNone(cohen_kappa([(True, True), (True, True)]))      # no variation: undefined
        lo, hi = wilson(9, 10)
        self.assertAlmostEqual(lo, 59.6, places=1)
        self.assertAlmostEqual(hi, 98.2, places=1)
        self.assertAlmostEqual(percentile([1, 2, 3, 4], 95), 3.85)

    def test_targets_file_matches_the_spec(self):
        t = common.load_targets()
        self.assertEqual(sorted(t, key=lambda e: int(e[1:])), [f"E{i}" for i in range(1, 12)])
        self.assertEqual(t["E1"]["kpis"]["map50"]["target"], 0.80)
        self.assertEqual(t["E4"]["kpis"]["test_agreement_pct"]["target"], 85.0)
        self.assertEqual(t["E9"]["kpis"]["sus_mean"]["target"], 68.0)
        self.assertEqual(t["E10"]["kpis"]["success_pct"]["target"], 60.0)

    def test_csv_reader_skips_comments_and_names_missing_columns(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.csv"
            p.write_text("# example: 1,2\na,b\n1,2\n\n", encoding="utf-8")
            self.assertEqual(common.read_csv(p, ["a", "b"]), [{"a": "1", "b": "2"}])
            with self.assertRaisesRegex(DataError, "missing column"):
                common.read_csv(p, ["a", "c"])


class E1E2E3Tests(TempDir):
    def test_e1_reads_the_evaluation_file(self):
        self.write("eval_test.json", json.dumps({"split": "test", "map50": 0.82, "map50_95": 0.51,
                                                 "per_class": {"boll_open": {"precision": 0.9, "recall": 0.83, "map50": 0.88}}}))
        r = e1(self.d)
        self.assertEqual((r.kpi("map50").status, r.kpi("open_boll_recall").status), ("MET", "MISSED"))
        self.assertEqual(r.status, "MISSED")
        self.write("eval_test.json", json.dumps({"split": "val", "map50": 0.9}))
        with self.assertRaisesRegex(DataError, "TEST farm"):
            e1(self.d)

    def test_e2_median_of_runs(self):
        self.write("speed_run1.json", json.dumps({"fps": 4.0}))
        self.write("speed_run2.json", json.dumps({"fps": 2.5}))
        r = e2(self.d)
        self.assertEqual(r.kpi("fps").value, 3.25)
        self.assertTrue(any("at least 3" in n for n in r.notes))

    def test_e3_cart_and_phone(self):
        rows = ["segment,cls,true,pred,mode", "S1,boll_open,10,9,cart", "S2,boll_open,20,22,cart", "S1,boll_open,10,7,phone"]
        self.write("counts.csv", "\n".join(rows) + "\n")
        self.write("scan_times.csv", "plot,acres,minutes\nA,0.5,25\nB,1,70\n")
        r = e3(self.d, self.d / "fig")
        self.assertEqual(r.kpi("cart_mape_open").value, 10.0)
        self.assertEqual(r.kpi("phone_mape_open").value, 30.0)
        self.assertEqual(r.kpi("scan_min_per_acre").value, 60.0)
        self.assertEqual(r.kpi("cart_mape_open").status, "MET")
        self.assertTrue(r.figures[0].exists())


class E4E5Tests(TempDir):
    def moisture(self, wet_rule):
        """90 samples at 11:00, 32 C, no rain. wet_rule(i, rh) -> True when the sample is wet (> 8 %)."""
        lines = ["sample_id,date,time,farm,segment,t_c,rh,rain_24h_mm,w_wet_g,w_dry_g"]
        for i in range(90):
            rh = 60 if i % 2 else 85
            dry = 15.0 * (0.88 if wet_rule(i, rh) else 0.95)   # 12 % or 5 % moisture
            lines.append(f"S{i},2026-11-{1 + i // 6:02d},11:00,F1,R001-S01,32,{rh},0,15.00,{dry:.2f}")
        return self.write("moisture.csv", "\n".join(lines) + "\n")

    def test_e4_rule_that_tracks_humidity_meets_the_target(self):
        self.moisture(lambda i, rh: rh > 75)
        r = e4(self.d, self.d / "fig")
        self.assertEqual(r.kpi("test_agreement_pct").value, 100.0)
        self.assertEqual(r.kpi("test_agreement_pct").status, "MET")
        self.assertEqual(r.tables["rules"][0]["test agreement %"], 100.0)   # the initial rule already agrees

    def test_e4_a_rule_unrelated_to_moisture_is_reported_as_missed(self):
        self.moisture(lambda i, rh: (i // 2) % 2 == 0)     # wetness independent of RH
        r = e4(self.d)
        self.assertEqual(r.kpi("test_agreement_pct").status, "MISSED")
        self.assertTrue(any("do not claim moisture sensing" in n for n in r.notes))

    def test_e4_needs_a_test_half(self):
        self.write("moisture.csv", "sample_id,date,time,farm,segment,t_c,rh,rain_24h_mm,w_wet_g,w_dry_g\nS1,2026-11-01,11:00,F1,R1,32,60,0,15,14\n")
        r = e4(self.d)
        self.assertEqual(r.kpi("test_agreement_pct").status, "NOT MEASURED")

    def test_e5_errors_and_segments(self):
        self.write("pegboard.csv", "point,true_x_m,true_y_m,true_z_m,est_x_m,est_y_m,est_z_m,arm_miss_cm\n"
                                   "P1,0,0,0.5,0.01,0,0.5,2\nP2,0,0,0.6,0,0.03,0.6,4\n")
        self.write("segments.csv", "row,true_segment,logged_segment\n1,R001-S01,R001-S01\n2,R002-S01,r002-s01\n")
        r = e5(self.d)
        self.assertAlmostEqual(r.kpi("mean_error_cm").value, 2.0)
        self.assertEqual(r.kpi("mean_error_cm").status, "MET")
        self.assertEqual(r.kpi("arm_within_3cm_pct").value, 50.0)
        self.assertEqual(r.kpi("segment_id_accuracy_pct").value, 100.0)


class E6E7Tests(TempDir):
    def test_e6_rule_cases_all_pass_on_the_real_engine(self):
        r = e6(REPO_E6)
        self.assertGreaterEqual(r.kpi("rule_cases").value, 30)
        failed = [c for c in r.tables["rule_cases"] if c["result"] != "PASS"]
        self.assertEqual(failed, [])

    def test_e6_a_wrong_expectation_fails(self):
        self.write("rule_cases.yaml", "- {id: X1, rule: aphid, expect: crossed, observations: [{observation: aphid_infested_plants, count: 2, units: 20}]}\n")
        r = e6(self.d)
        self.assertEqual(r.kpi("rule_cases_pass_pct").status, "MISSED")

    def test_e6_camera_vs_scouting(self):
        shutil.copy(REPO_E6 / "rule_cases.yaml", self.d)
        self.write("pest_signals.csv", "segment,cls,camera_count,scout_found\nS1,mealybug_colony,2,1\nS2,mealybug_colony,0,1\nS3,mealybug_colony,1,0\nS4,boll_bored,3,yes\n")
        r = e6(self.d)
        self.assertAlmostEqual(r.kpi("camera_precision_5_7").value, 2 / 3)
        self.assertAlmostEqual(r.kpi("camera_recall_5_7").value, 2 / 3)

    def test_card_deposit_from_a_photo(self):
        import cv2
        import numpy as np
        img = np.full((100, 100, 3), 255, np.uint8)
        img[:, :30] = (200, 60, 0)                       # BGR blue dye on the left 30 %
        path = self.d / "card.png"
        cv2.imwrite(str(path), img)
        self.assertAlmostEqual(card_deposit_pct(path), 30.0, places=1)

    def test_e7(self):
        rows = ["plant_id,card,deposit_pct,image"] + [f"T{i},target,{50 if i < 9 else 5}," for i in range(10)] + \
               [f"N{i},neighbour,{20 if i < 1 else 0}," for i in range(20)]
        self.write("cards.csv", "\n".join(rows) + "\n")
        self.write("volume.csv", "tank_before_g,tank_after_g\n5000,4000\n")
        r = e7(self.d)
        self.assertEqual(r.kpi("target_hit_pct").value, 90.0)
        self.assertEqual(r.kpi("non_target_hit_pct").value, 5.0)
        self.assertAlmostEqual(r.kpi("volume_vs_blanket_pct").value, 1000 / 2700 * 100)
        self.assertEqual(r.status, "MET")


class E8ToE11Tests(TempDir):
    def test_e8_reconciliation(self):
        ob = Outbox(self.d / "outbox.sqlite")
        t0 = datetime(2026, 11, 10, 4, 0, tzinfo=timezone.utc)
        lines = ["msg_id,received_at"]
        for i in range(10):
            created = t0 + timedelta(minutes=i)
            ob.put("scan", f"s{i}", {"i": i}, now=created.timestamp())
        ob.put("heartbeat", "cart01", {}, now=t0.timestamp())
        items = ob.pending(100)
        for item in items:
            ob.mark_sent(item.id)
        ob.close()
        for i, item in enumerate(i for i in items if i.kind == "scan"):
            if i == 9:
                continue                                        # lost
            created = t0 + timedelta(minutes=i)
            delay = 3600 if 3 <= i <= 5 else 2                  # minutes 3-5 were offline
            lines.append(f"{item.msg_id},{(created + timedelta(seconds=delay)).isoformat()}")
        self.write("backend_messages.csv", "\n".join(lines) + "\n")
        self.write("session.yaml", "offline_start: 2026-11-10T04:03:00+00:00\noffline_end: 2026-11-10T04:05:30+00:00\n")
        r = e8(self.d, self.d / "fig")
        self.assertEqual(r.kpi("lost_messages").value, 1)
        self.assertEqual(r.kpi("lost_messages").status, "MISSED")
        self.assertEqual(r.kpi("median_latency_online_s").value, 2.0)
        self.assertEqual(r.tables["summary"][0]["created while offline"], 3)
        self.assertEqual(r.n, 10, "heartbeats are not reconciled")

    def test_sus_formula(self):
        self.assertEqual(sus_score([5, 1] * 5), 100.0)
        self.assertEqual(sus_score([3] * 10), 50.0)
        self.assertEqual(sus_score([1, 5] * 5), 0.0)
        with self.assertRaises(DataError):
            sus_score([6] * 10)

    def test_e9(self):
        head = "participant,village,q1,q2,q3,q4,q5,q6,q7,q8,q9,q10,task_pick_list,task_tamil_alert,task_trap_count"
        self.write("sus.csv", "\n".join([head, "P01,A," + ",".join(["5", "1"] * 5) + ",1,1,1",
                                         "P02,B," + ",".join(["3"] * 10) + ",1,0,1"]) + "\n")
        r = e9(self.d)
        self.assertEqual(r.kpi("sus_mean").value, 75.0)
        self.assertAlmostEqual(r.kpi("task_completion_pct").value, 500 / 6)
        self.assertEqual(r.status, "MET")
        self.assertTrue(any("at least 10" in n for n in r.notes))

    def test_e10(self):
        head = "id,ts,farm,segment,track_id,conf,cam_xyz,base_xyz,pitch_deg,result,reason,t_approach_s,t_contact_s,t_dwell_s,t_retract_s,cycle_s,outcome,lint_left_g,trash_g,notes,setting,effector,picked_g"
        rows = [head]
        for i in range(10):
            ok = i < 7
            rows.append(f"p{i},,F1,R1,{i},0.9,,,,completed,{'' if ok else 'slipped'},1,1,2,1,{10 + i},{'picked' if ok else 'partial'},"
                        f"{0.5 if ok else 3},{0.2},,bench,vacuum,{4.5 if ok else 1}")
        rows.append(f"c0,,F1,R1,1,0.9,,,,completed,,1,1,2,1,20,missed,4,0,,bench,claw,0")
        self.write("picks.csv", "\n".join(rows) + "\n")
        r = e10(self.d, self.d / "fig")
        self.assertEqual(r.kpi("success_pct").value, 70.0)
        self.assertEqual(r.kpi("cycle_median_s").value, 14.5)
        self.assertEqual(r.n, 10, "the claw baseline is reported separately")
        self.assertEqual({g["effector"] for g in r.tables["by_setting_and_effector"]}, {"vacuum", "claw"})
        self.assertEqual(r.tables["failure_reasons"][0], {"reason": "slipped", "count": 3})

    def test_e11(self):
        start = datetime(2026, 11, 12, 9, 0, tzinfo=IST)
        rows = ["ts,voltage_v,current_a"] + [f"{(start + timedelta(minutes=10 * i)).isoformat()},12.0,1.0" for i in range(7)]
        self.write("power_day1.csv", "\n".join(rows) + "\n")
        self.write("session.yaml", "battery_wh: 100\nusable_fraction: 0.8\n")
        r = e11(self.d)
        self.assertAlmostEqual(r.kpi("mean_power_w").value, 12.0)
        self.assertAlmostEqual(r.kpi("runtime_h").value, 80 / 12)
        self.assertEqual(r.kpi("runtime_h").status, "MET")


class ReportTests(TempDir):
    def test_report_lists_every_experiment_and_keeps_misses_and_data_problems(self):
        shutil.copytree(REPO_E6, self.d / "E6")
        self.write("E2/speed_run1.json", json.dumps({"fps": 2.0}))
        self.write("E9/sus.csv", "participant,village\nP1,A\n")        # broken: columns missing
        results = run_all(self.d)
        self.assertEqual([r.exp for r in results], [f"E{i}" for i in range(1, 12)])
        by = {r.exp: r for r in results}
        self.assertEqual(by["E2"].status, "MISSED")
        self.assertEqual(by["E6"].status, "MET")
        self.assertEqual(by["E1"].status, "NO DATA")
        self.assertTrue(any(n.startswith("DATA PROBLEM") for n in by["E9"].notes))
        md = to_markdown(results, self.d)
        self.assertIn("| E2 | Throughput (median of runs), FPS | 2 | >= 3 | MISSED |", md)
        self.assertIn(common.targets_sha256()[:16], md)


if __name__ == "__main__":
    unittest.main()
