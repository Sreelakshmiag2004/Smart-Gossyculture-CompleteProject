"""Plan and execute one pick (spec Section 10, experiment E10).

Pick cycle for one open boll:
  1. move to the PRE point (standoff before the boll, same approach angle)
  2. picking head ON (blower + rollers; firmware auto-off as a backstop)
  3. move slowly to the CONTACT point (boll surface)
  4. dwell (head draws the lint in)
  5. retract to the PRE point
  6. head OFF
Any failure (E-stop, dead-man released, rejected move, timeout) switches the
head off and ends the attempt as 'aborted' with the reason. Every attempt,
including unreachable targets, is logged for E10.
"""
from __future__ import annotations

import csv
import math
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional, Protocol, Sequence

from bollbot.core.models import CLASSES
from ..counting import Detection
from .handeye import HandEye
from .kinematics import ArmKinematics, Unreachable, approach_vector

OPEN = CLASSES.index("boll_open")


class Arm(Protocol):
    def move(self, angles: Optional[list[float]] = None, speed_dps: float = 30.0,
             home: bool = False, timeout_s: float = 15.0) -> str: ...
    def effector(self, on: bool, ms: int = 0, timeout_s: float = 3.0) -> None: ...


@dataclass
class PickPlan:
    cam_xyz: tuple[float, float, float]
    base_xyz: tuple[float, float, float]
    contact_xyz: tuple[float, float, float]
    pre_xyz: tuple[float, float, float]
    pre_deg: list[float]
    contact_deg: list[float]
    pitch_deg: float
    elbow: str


@dataclass
class PickAttempt:
    id: str
    ts: str
    farm: str
    segment: str
    track_id: Optional[int]
    conf: float
    cam_xyz: Optional[list[float]]
    base_xyz: Optional[list[float]] = None
    pitch_deg: Optional[float] = None
    result: str = ""                 # completed | unreachable | aborted
    reason: str = ""
    t_approach_s: float = 0.0
    t_contact_s: float = 0.0
    t_dwell_s: float = 0.0
    t_retract_s: float = 0.0
    cycle_s: float = 0.0             # first move start -> head off
    # filled in by the operator after inspecting the boll (E10):
    outcome: str = ""                # picked | partial | missed | damaged
    lint_left_g: Optional[float] = None
    trash_g: Optional[float] = None
    notes: str = ""


def _add(a, b, k=1.0):
    return tuple(x + k * y for x, y in zip(a, b))


class Picker:
    def __init__(self, arm_cfg: dict, kin: ArmKinematics, handeye: HandEye, arm: Arm,
                 mono: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep):
        self.p = arm_cfg["pick"]
        self.kin, self.he, self.arm = kin, handeye, arm
        self.mono, self.sleep = mono, sleep
        self.current: Optional[list[float]] = None      # last commanded pose (for IK preference)

    # ---------------------------------------------------------- planning
    def plan(self, cam_xyz: Sequence[float]) -> PickPlan:
        """Camera point (m) -> arm plan. Raises Unreachable."""
        return self.plan_base(self.he.to_base(cam_xyz), tuple(cam_xyz))

    def plan_base(self, base: Sequence[float], cam_xyz=None) -> PickPlan:
        """Boll centre in the ARM BASE frame -> plan. Raises Unreachable."""
        base = tuple(float(v) for v in base)
        yaw = math.atan2(base[1], base[0])
        r_boll, standoff = float(self.p["boll_radius_m"]), float(self.p["standoff_m"])

        def contact_at(pitch: float):
            return _add(base, approach_vector(yaw, pitch), -r_boll)

        def pre_at(pitch: float):
            return _add(base, approach_vector(yaw, pitch), -(r_boll + standoff))

        # The contact point itself depends on the pitch, so solve per pitch:
        last = "no solution"
        tol, pref = float(self.p["pitch_tolerance_deg"]), float(self.p["preferred_pitch_deg"])
        offsets = [0.0] + [s * k for k in range(5, int(tol) + 1, 5) for s in (-1, 1)]
        for off in offsets:
            pitch = math.radians(pref + off)
            try:
                sol, pre_deg = self.kin.solve(contact_at(pitch), pref + off, 0.0,
                                              current=self.current, also=lambda _p, pitch=pitch: pre_at(pitch))
            except Unreachable as e:
                last = str(e)
                continue
            return PickPlan(tuple(cam_xyz) if cam_xyz is not None else base, base,
                            contact_at(pitch), pre_at(pitch),
                            pre_deg, sol.servo_deg, sol.pitch_deg, sol.elbow)
        raise Unreachable(last)

    # --------------------------------------------------------- execution
    def pick(self, det: Detection, farm: str = "", segment: str = "",
             now: Callable[[], datetime] = datetime.now) -> PickAttempt:
        att = PickAttempt(id=f"p-{uuid.uuid4().hex[:10]}", ts=now().isoformat(timespec="seconds"),
                          farm=farm, segment=segment, track_id=det.track_id, conf=round(det.conf, 3),
                          cam_xyz=[round(v, 4) for v in det.xyz_m] if det.xyz_m else None)
        if det.xyz_m is None:
            att.result, att.reason = "unreachable", "no depth for this detection"
            return att
        try:
            plan = self.plan(det.xyz_m)
        except Unreachable as e:
            att.result, att.reason = "unreachable", str(e)
            return att
        att.base_xyz = [round(v, 4) for v in plan.base_xyz]
        att.pitch_deg = plan.pitch_deg
        dwell = float(self.p["dwell_s"])
        head_ms = int((dwell + 8.0) * 1000)        # covers approach + dwell; firmware cap 10 s
        t0 = self.mono()
        head_on = False
        try:
            self.arm.move(plan.pre_deg, self.p["approach_speed_dps"])
            self.current = plan.pre_deg
            t1 = self.mono()
            self.arm.effector(True, min(head_ms, 10000))
            head_on = True
            self.arm.move(plan.contact_deg, self.p["final_speed_dps"])
            self.current = plan.contact_deg
            t2 = self.mono()
            self.sleep(dwell)
            t3 = self.mono()
            self.arm.move(plan.pre_deg, self.p["final_speed_dps"])
            self.current = plan.pre_deg
            t4 = self.mono()
            self.arm.effector(False)
            head_on = False
            att.result = "completed"
            att.t_approach_s, att.t_contact_s = round(t1 - t0, 2), round(t2 - t1, 2)
            att.t_dwell_s, att.t_retract_s = round(t3 - t2, 2), round(t4 - t3, 2)
        except Exception as e:  # noqa: BLE001 - any failure aborts this attempt safely
            att.result, att.reason = "aborted", f"{type(e).__name__}: {e}"
        finally:
            if head_on:
                try:
                    self.arm.effector(False)
                except Exception:  # noqa: BLE001 - firmware auto-off is the backstop
                    pass
            att.cycle_s = round(self.mono() - t0, 2)
        return att


def select_targets(dets: Sequence[Detection], picker: Picker, attempted: dict[int, int],
                   max_attempts: int, min_conf: float, max_range_m: float) -> list[tuple[Detection, PickPlan]]:
    """Open bolls worth trying now, nearest to the arm base first."""
    out = []
    for d in dets:
        if d.cls_id != OPEN or d.conf < min_conf or d.xyz_m is None:
            continue
        if math.dist((0, 0, 0), d.xyz_m) > max_range_m or d.xyz_m[2] <= 0:
            continue
        if d.track_id is not None and attempted.get(d.track_id, 0) >= max_attempts:
            continue
        try:
            plan = picker.plan(d.xyz_m)
        except Unreachable:
            continue
        out.append((d, plan))
    return sorted(out, key=lambda dp: math.dist((0, 0, 0), dp[1].base_xyz))


class AttemptLog:
    """Append-only CSV for E10 (one row per attempt) + optional outbox copy."""

    FIELDS = list(PickAttempt.__dataclass_fields__)

    def __init__(self, path: str | Path, outbox=None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.outbox = outbox
        if not self.path.exists():
            with open(self.path, "w", newline="", encoding="utf-8") as fh:
                csv.DictWriter(fh, self.FIELDS).writeheader()

    def write(self, att: PickAttempt) -> None:
        row = asdict(att)
        for k in ("cam_xyz", "base_xyz"):
            row[k] = "" if row[k] is None else ";".join(str(v) for v in row[k])
        with open(self.path, "a", newline="", encoding="utf-8") as fh:
            csv.DictWriter(fh, self.FIELDS).writerow(row)
        if self.outbox is not None:
            self.outbox.put("pick_attempt", att.id, asdict(att))
