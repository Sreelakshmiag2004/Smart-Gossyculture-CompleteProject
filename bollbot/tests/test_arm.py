"""Tests for robotic harvesting (Module 5)."""
import csv
import math
import random
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

import numpy as np

from bollbot.core.models import CLASSES
from bollbot.edge.arm.handeye import CalibrationError, HandEye, fit
from bollbot.edge.arm.harvest import harvest_session, load_arm_config, summarise
from bollbot.edge.arm.kinematics import ArmKinematics, Unreachable
from bollbot.edge.arm.picker import AttemptLog, Picker, select_targets
from bollbot.edge.counting import Detection

OPEN, CLOSED = CLASSES.index("boll_open"), CLASSES.index("boll_closed")
ARM = load_arm_config()
WIDE = {**ARM, "joints": [{"name": n, "zero_deg": 90, "direction": d, "min_deg": 0, "max_deg": 180}
                          for n, d in (("base", 1), ("shoulder", 1), ("elbow", -1), ("wrist", 1))]}
IDENTITY = HandEye(np.eye(3), np.zeros(3), 0.0, 0.0, 10)


def close(a, b, tol=1e-6):
    return all(abs(x - y) < tol for x, y in zip(a, b))


class KinematicsTests(unittest.TestCase):
    def test_fk_home(self):
        kin = ArmKinematics(WIDE)          # all joints at reference: arm straight out, horizontal
        p, pitch = kin.fk([90, 90, 90, 90])
        L = WIDE["links_m"]
        self.assertTrue(close(p, (L["upper_arm"] + L["forearm"] + L["tool"], 0, L["base_height"])))
        self.assertAlmostEqual(pitch, 0.0)

    def test_ik_round_trip_random(self):
        for absolute in (False, True):
            kin = ArmKinematics({**WIDE, "forearm_absolute": absolute})
            rnd = random.Random(1)
            checked = 0
            for _ in range(300):
                servo = [rnd.uniform(10, 170) for _ in range(4)]
                target, pitch = kin.fk(servo)
                yaw = kin.joint_angles(servo)[0]
                reach = target[0] * math.cos(yaw) + target[1] * math.sin(yaw)
                if reach < 0.02:          # arm folded back over itself: approach would be mirrored
                    continue
                try:
                    sol = kin.ik(target, pitch, "up")
                except Unreachable:
                    sol = kin.ik(target, pitch, "down")
                p2, pitch2 = kin.fk(sol)
                self.assertTrue(close(p2, target, 1e-4), (servo, sol))
                self.assertAlmostEqual(pitch2, pitch, delta=math.radians(0.016))  # 3 joints x 0.005 deg rounding
                checked += 1
            self.assertGreater(checked, 250)

    def test_unreachable_and_limits(self):
        kin = ArmKinematics(ARM)
        with self.assertRaisesRegex(Unreachable, "reach"):
            kin.ik((2.0, 0, 0.1), 0.0)
        with self.assertRaisesRegex(Unreachable, "base axis"):
            kin.ik((0, 0, 0.3), 0.0)
        with self.assertRaisesRegex(Unreachable, "joint limits"):
            kin.ik((-0.3, -0.01, 0.1), 0.0)            # behind the arm: base yaw ~ -178 deg

    def test_solve_prefers_pitch_and_current_pose(self):
        kin = ArmKinematics(WIDE)
        target, pitch = kin.fk([100, 110, 120, 100])     # shoulder 20, elbow -30, wrist 10 -> pitch 0
        self.assertAlmostEqual(pitch, 0.0)
        sol, _ = kin.solve(target, preferred_pitch_deg=0, tolerance_deg=30)
        self.assertEqual(sol.pitch_deg, 0)
        up, _ = kin.solve(target, 0, 0, current=kin.ik(target, 0.0, "up"))
        down, _ = kin.solve(target, 0, 0, current=kin.ik(target, 0.0, "down"))
        self.assertEqual((up.elbow, down.elbow), ("up", "down"))

    def test_bad_config(self):
        with self.assertRaises(ValueError):
            ArmKinematics({**ARM, "joints": ARM["joints"][:3]})
        with self.assertRaises(ValueError):
            ArmKinematics({**ARM, "links_m": {**ARM["links_m"], "forearm": 0}})


def random_rotation(rnd):
    q = np.array([rnd.gauss(0, 1) for _ in range(4)])
    q /= np.linalg.norm(q)
    w, x, y, z = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


class HandEyeTests(unittest.TestCase):
    def setUp(self):
        rnd = random.Random(7)
        self.R, self.t = random_rotation(rnd), np.array([0.2, -0.1, 0.35])
        self.cam = np.array([[rnd.uniform(-0.2, 0.2), rnd.uniform(-0.2, 0.2), rnd.uniform(0.3, 0.8)]
                             for _ in range(10)])
        self.base = self.cam @ self.R.T + self.t

    def test_recovers_transform_with_noise(self):
        noisy = self.base + np.random.default_rng(0).normal(0, 0.002, self.base.shape)
        he = fit(self.cam, noisy)
        self.assertTrue(np.allclose(he.R, self.R, atol=0.03))
        self.assertLess(np.linalg.norm(he.t - self.t), 0.01)
        self.assertLess(he.rms_m, 0.004)
        self.assertTrue(close(he.to_base(self.cam[0]), self.base[0], 0.01))

    def test_mirrored_camera_is_not_hidden(self):
        mirrored = self.cam * np.array([1, -1, 1])          # wrong handedness
        he = fit(mirrored, self.base)
        self.assertAlmostEqual(np.linalg.det(he.R), 1.0)
        self.assertGreater(he.rms_m, 0.02)                   # big residual flags it

    def test_rejects_bad_input(self):
        with self.assertRaisesRegex(CalibrationError, "at least 4"):
            fit(self.cam[:3], self.base[:3])
        line = np.array([[0, 0, z] for z in (0.3, 0.4, 0.5, 0.6)], float)
        with self.assertRaisesRegex(CalibrationError, "collinear"):
            fit(line, line + 0.1)

    def test_save_load(self):
        he = fit(self.cam, self.base)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "he.json"
            he.save(p)
            back = HandEye.load(p)
            self.assertTrue(np.allclose(back.R, he.R))
            p.write_text('{"R": [[2,0,0],[0,1,0],[0,0,1]], "t": [0,0,0], "rms_m": 0, "max_err_m": 0, "n": 4}')
            with self.assertRaisesRegex(CalibrationError, "rotation"):
                HandEye.load(p)
            with self.assertRaisesRegex(CalibrationError, "no calibration"):
                HandEye.load(Path(d) / "missing.json")


class FakeArm:
    def __init__(self, fail_on_call=None, clock=None):
        self.calls, self.fail_on_call, self.clock = [], fail_on_call, clock

    def _step(self, entry):
        self.calls.append(entry)
        if self.clock is not None:
            self.clock[0] += 1.5
        if self.fail_on_call is not None and len(self.calls) == self.fail_on_call:
            raise RuntimeError("deadman_released")

    def move(self, angles=None, speed_dps=30.0, home=False, timeout_s=15.0):
        self._step(("move", tuple(angles) if angles else "home", speed_dps))
        return "m"

    def effector(self, on, ms=0, timeout_s=3.0):
        self._step(("effector", on))


def det(xyz, cls=OPEN, conf=0.9, tid=1):
    return Detection(cls, conf, (0, 0, 10, 10), tid, xyz)


REACHABLE = (0.33, 0.03, 0.18)       # inside the default pickable band (x 0.29-0.39 m)


class PickerTests(unittest.TestCase):
    def make(self, arm=None, clock=None):
        clock = clock or [0.0]
        return Picker(ARM, ArmKinematics(ARM), IDENTITY, arm or FakeArm(clock=clock),
                      mono=lambda: clock[0], sleep=lambda s: clock.__setitem__(0, clock[0] + s)), clock

    def test_plan_geometry(self):
        p, _ = self.make()
        kin = ArmKinematics(ARM)
        plan = p.plan(REACHABLE)
        self.assertTrue(close(kin.fk(plan.contact_deg)[0], plan.contact_xyz, 1e-3))
        self.assertTrue(close(kin.fk(plan.pre_deg)[0], plan.pre_xyz, 1e-3))
        gap = math.dist(plan.pre_xyz, plan.contact_xyz)
        self.assertAlmostEqual(gap, ARM["pick"]["standoff_m"], places=4)
        self.assertAlmostEqual(math.dist(plan.contact_xyz, plan.base_xyz), ARM["pick"]["boll_radius_m"], places=4)

    def test_pick_sequence_and_timing(self):
        arm = FakeArm()
        p, clock = self.make(arm)
        arm.clock = clock
        att = p.pick(det(REACHABLE), "F01", "R003-S02")
        self.assertEqual(att.result, "completed")
        kinds = [c[0] if c[0] == "move" else (c[0], c[1]) for c in arm.calls]
        self.assertEqual(kinds, ["move", ("effector", True), "move", "move", ("effector", False)])
        self.assertEqual(arm.calls[2][2], ARM["pick"]["final_speed_dps"])     # slow final approach
        self.assertEqual(att.t_dwell_s, ARM["pick"]["dwell_s"])
        self.assertEqual(att.cycle_s, 5 * 1.5 + ARM["pick"]["dwell_s"])

    def test_abort_switches_head_off(self):
        arm = FakeArm(fail_on_call=3)                  # fails during the move to the boll
        p, _ = self.make(arm)
        att = p.pick(det(REACHABLE))
        self.assertEqual(att.result, "aborted")
        self.assertIn("deadman_released", att.reason)
        self.assertEqual(arm.calls[-1], ("effector", False))

    def test_unreachable_and_no_depth(self):
        p, _ = self.make()
        self.assertEqual(p.pick(det((1.5, 0, 0.2))).result, "unreachable")
        att = p.pick(det(None))
        self.assertEqual((att.result, att.reason), ("unreachable", "no depth for this detection"))

    def test_select_targets(self):
        p, _ = self.make()
        near, far = (0.33, 0.0, 0.14), (0.37, 0.03, 0.18)
        dets = [det(far, tid=1), det(near, tid=2), det(near, cls=CLOSED, tid=3),
                det(near, conf=0.3, tid=4), det((1.5, 0, 0.2), tid=5), det(None, tid=6),
                det(near, tid=7)]
        got = select_targets(dets, p, {7: 1}, 1, 0.5, 0.8)
        self.assertEqual([d.track_id for d, _ in got], [2, 1])


class SessionTests(unittest.TestCase):
    def run_session(self, frames, arm=None, ask=None, max_picks=10):
        clock = [0.0]
        arm = arm or FakeArm(clock=clock)
        picker = Picker(ARM, ArmKinematics(ARM), IDENTITY, arm, mono=lambda: clock[0], sleep=lambda s: None)
        d = tempfile.mkdtemp()
        log = AttemptLog(Path(d) / "E10" / "picks.csv")
        atts = harvest_session(iter(frames), picker, log, ARM, "F01", "R003-S02", max_picks, ask,
                               give_up_after_frames=3, skip_after_pick=1)
        return atts, log, arm

    def test_each_boll_tried_once_and_logged(self):
        f = (datetime.now(), None, [det((0.33, 0.0, 0.14), tid=1), det((0.37, 0.03, 0.18), tid=2)])
        frames = [f] * 12
        def ask(a): a.outcome = "picked"
        atts, log, _ = self.run_session(frames, ask=ask)
        self.assertEqual([a.track_id for a in atts], [1, 2])
        rows = list(csv.DictReader(open(log.path, encoding="utf-8")))
        self.assertEqual([r["outcome"] for r in rows], ["picked", "picked"])
        s = summarise(atts)
        self.assertEqual((s["completed"], s["success_rate"]), (2, 1.0))

    def test_session_stops_on_abort(self):
        f = (datetime.now(), None, [det((0.33, 0.0, 0.14), tid=1), det((0.37, 0.03, 0.18), tid=2)])
        atts, _, _ = self.run_session([f] * 10, arm=FakeArm(fail_on_call=1))
        self.assertEqual([a.result for a in atts], ["aborted"])

    def test_gives_up_when_nothing_pickable(self):
        empty = (datetime.now(), None, [])
        atts, _, arm = self.run_session([empty] * 50)
        self.assertEqual(atts, [])
        self.assertEqual(arm.calls, [])


class WorkspaceTests(unittest.TestCase):
    def test_map_matches_planner(self):
        from bollbot.edge.arm.harvest import workspace_map
        p = Picker(ARM, ArmKinematics(ARM), IDENTITY, None)
        rows, xr = workspace_map(p)
        self.assertTrue(any("#" in r for r in rows))
        lo, hi = xr
        self.assertLess(lo, REACHABLE[0]); self.assertGreater(hi, REACHABLE[0])


class ConfigConsistencyTests(unittest.TestCase):
    def test_arm_yaml_matches_firmware_limits(self):
        import re
        from bollbot.core.config import CONFIG_DIR
        h = (CONFIG_DIR.parent / "firmware" / "esp32" / "bollbot_fw" / "config.h").read_text()
        fw = [(float(a), float(b)) for a, b in
              re.findall(r"\{\s*([\d.]+)f,\s*([\d.]+)f,\s*[\d.]+f,\s*\d+", h)]
        yml = [(j["min_deg"], j["max_deg"]) for j in ARM["joints"]]
        self.assertEqual(fw, yml, "edit config.h kJoints and config/arm.yaml together")


class SyncDeadLetterTests(unittest.TestCase):
    def test_unknown_kind_does_not_block_queue(self):
        import logging
        from bollbot.edge.store import Outbox
        from bollbot.edge.contract import KINDS
        from bollbot.edge.sync import PermanentUploadError, SyncService
        for kind in ("scan", "heartbeat", "spray_event", "pick_attempt"):
            self.assertIn(kind, KINDS)               # every kind the cart writes has a contract message

        class Up:
            def __init__(self): self.got = []
            def upload(self, kind, doc_id, payload, **kw):
                if kind not in KINDS:
                    raise PermanentUploadError(kind)
                self.got.append(doc_id)
        ob = Outbox(); self.addCleanup(ob.close)
        ob.put("mystery", "x", {}); ob.put("scan", "a", {})
        up = Up()
        logging.getLogger("bollbot.edge.sync").disabled = True
        try:
            self.assertEqual(SyncService(ob, up).step(), 1)
        finally:
            logging.getLogger("bollbot.edge.sync").disabled = False
        self.assertEqual(up.got, ["a"])
        self.assertEqual((ob.stats()["dead"], ob.stats()["pending"]), (1, 0))


if __name__ == "__main__":
    unittest.main()
