"""Forward and inverse kinematics for the 4-DOF picking arm (spec Section 10).

Joints: base yaw, shoulder pitch, elbow pitch, wrist pitch. With yaw fixed,
the shoulder, elbow and wrist form a planar 3-link chain, solved
analytically: the wrist point comes from the target and the approach pitch,
then the standard two-link solution gives shoulder and elbow, and the wrist
takes up the remaining angle.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, Optional, Sequence

Vec3 = tuple[float, float, float]


class Unreachable(ValueError):
    pass


@dataclass(frozen=True)
class Joint:
    name: str
    zero_deg: float
    direction: int
    min_deg: float
    max_deg: float

    def to_servo(self, joint_rad: float) -> float:
        return self.zero_deg + self.direction * math.degrees(joint_rad)

    def to_joint(self, servo_deg: float) -> float:
        return math.radians((servo_deg - self.zero_deg) * self.direction)

    def ok(self, servo_deg: float) -> bool:
        return self.min_deg - 1e-6 <= servo_deg <= self.max_deg + 1e-6


@dataclass
class IKSolution:
    servo_deg: list[float]
    pitch_deg: float
    elbow: str             # "up" | "down"


class ArmKinematics:
    def __init__(self, cfg: dict):
        L = cfg["links_m"]
        self.L0, self.L1, self.L2, self.L3 = (float(L[k]) for k in
                                              ("base_height", "upper_arm", "forearm", "tool"))
        if min(self.L1, self.L2, self.L3) <= 0 or self.L0 < 0:
            raise ValueError("link lengths must be positive")
        js = cfg["joints"]
        if len(js) != 4:
            raise ValueError("expected 4 joints: base, shoulder, elbow, wrist")
        self.joints = [Joint(j["name"], float(j["zero_deg"]), int(j["direction"]),
                             float(j["min_deg"]), float(j["max_deg"])) for j in js]
        for j in self.joints:
            if j.direction not in (1, -1) or j.min_deg >= j.max_deg:
                raise ValueError(f"joint {j.name}: direction must be +/-1 and min < max")
        self.forearm_absolute = bool(cfg.get("forearm_absolute", False))

    # ------------------------------------------------------------ forward
    def joint_angles(self, servo_deg: Sequence[float]) -> tuple[float, float, float, float]:
        """Servo degrees -> (yaw, shoulder, elbow_relative, wrist_relative) in radians."""
        b, s, e, w = (j.to_joint(d) for j, d in zip(self.joints, servo_deg))
        if self.forearm_absolute:
            e = e - s           # servo gives forearm angle to horizontal
        return b, s, e, w

    def fk(self, servo_deg: Sequence[float]) -> tuple[Vec3, float]:
        """Tool-tip position (arm base frame, m) and approach pitch (rad)."""
        yaw, t1, t2, t3 = self.joint_angles(servo_deg)
        r = self.L1 * math.cos(t1) + self.L2 * math.cos(t1 + t2) + self.L3 * math.cos(t1 + t2 + t3)
        z = self.L0 + self.L1 * math.sin(t1) + self.L2 * math.sin(t1 + t2) + self.L3 * math.sin(t1 + t2 + t3)
        return (r * math.cos(yaw), r * math.sin(yaw), z), t1 + t2 + t3

    # ------------------------------------------------------------ inverse
    def ik(self, target: Vec3, pitch_rad: float, elbow: str = "up") -> list[float]:
        """Servo degrees placing the tool tip at target with the given approach
        pitch. Raises Unreachable (out of reach or outside joint limits)."""
        x, y, z = target
        r_t = math.hypot(x, y)
        if r_t < 1e-6:
            raise Unreachable("target on the base axis")
        yaw = math.atan2(y, x)
        rw = r_t - self.L3 * math.cos(pitch_rad)
        zw = (z - self.L0) - self.L3 * math.sin(pitch_rad)
        d2 = rw * rw + zw * zw
        c2 = (d2 - self.L1 ** 2 - self.L2 ** 2) / (2 * self.L1 * self.L2)
        if c2 > 1 + 1e-9 or c2 < -1 - 1e-9:
            raise Unreachable(f"wrist point {math.sqrt(d2):.3f} m away, reach "
                              f"{abs(self.L1 - self.L2):.3f}-{self.L1 + self.L2:.3f} m")
        c2 = max(-1.0, min(1.0, c2))
        t2 = -math.acos(c2) if elbow == "up" else math.acos(c2)
        t1 = math.atan2(zw, rw) - math.atan2(self.L2 * math.sin(t2), self.L1 + self.L2 * math.cos(t2))
        t3 = pitch_rad - t1 - t2
        elbow_servo = t1 + t2 if self.forearm_absolute else t2
        servo = [self.joints[0].to_servo(yaw), self.joints[1].to_servo(t1),
                 self.joints[2].to_servo(elbow_servo), self.joints[3].to_servo(t3)]
        bad = [f"{j.name} {d:.1f} not in [{j.min_deg}, {j.max_deg}]"
               for j, d in zip(self.joints, servo) if not j.ok(d)]
        if bad:
            raise Unreachable("joint limits: " + "; ".join(bad))
        return [round(d, 2) for d in servo]

    def solve(self, target: Vec3, preferred_pitch_deg: float = 0.0, tolerance_deg: float = 30.0,
              current: Optional[Sequence[float]] = None, step_deg: float = 5.0,
              also: Optional[Callable[[float], Vec3]] = None) -> tuple[IKSolution, Optional[list[float]]]:
        """Search pitches nearest the preferred one first; for each, try both
        elbow configurations and keep the one closest to `current`.
        If `also` is given, also(pitch_rad) returns a second point (the
        pre-pick point, which depends on the approach pitch) that must be
        reachable with the SAME pitch and elbow, so the head approaches in a
        straight line. Returns (solution, servo angles for that second point)."""
        offsets = [0.0]
        k = 1
        while k * step_deg <= tolerance_deg + 1e-9:
            offsets += [-k * step_deg, k * step_deg]
            k += 1
        last_err = "no solution"
        for off in offsets:
            pitch = math.radians(preferred_pitch_deg + off)
            found = []
            for elbow in ("up", "down"):
                try:
                    sol = self.ik(target, pitch, elbow)
                    other = self.ik(also(pitch), pitch, elbow) if also is not None else None
                    found.append((elbow, sol, other))
                except Unreachable as e:
                    last_err = str(e)
            if found:
                if current is not None:
                    found.sort(key=lambda es: sum(abs(a - b) for a, b in zip(es[1], current)))
                elbow, sol, other = found[0]
                return IKSolution(sol, preferred_pitch_deg + off, elbow), other
        raise Unreachable(last_err)


def approach_vector(yaw_rad: float, pitch_rad: float) -> Vec3:
    """Unit vector of the head's approach direction in the arm base frame."""
    return (math.cos(pitch_rad) * math.cos(yaw_rad), math.cos(pitch_rad) * math.sin(yaw_rad),
            math.sin(pitch_rad))
