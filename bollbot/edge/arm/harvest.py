"""Robotic harvesting from a parked cart (spec Section 10, experiments E5, E10).

  python -m bollbot.edge.arm.harvest workspace                    # where bolls must be to be pickable
  python -m bollbot.edge.arm.harvest plan                         # detect + plan only, NO motion
  python -m bollbot.edge.arm.harvest goto --base 0.30 0.00 0.15  # move the nozzle to a point (E5 touch test)
  python -m bollbot.edge.arm.harvest run --segment R003-S02 --max-picks 10 --confirm

'run' needs the operator to HOLD the dead-man button the whole time; letting
go stops the arm (held in place) and the picking head immediately. With
--confirm, the operator scores each attempt (picked / partial / missed /
damaged) right after it, which E10 needs.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterator, Optional

import yaml

from bollbot.core.config import CONFIG_DIR
from bollbot.core.rules import IST
from ..counting import Detection
from .handeye import HandEye
from .kinematics import ArmKinematics, Unreachable
from .picker import AttemptLog, PickAttempt, Picker, select_targets

PACKAGE_DIR = CONFIG_DIR.parent
OUTCOMES = {"p": "picked", "a": "partial", "m": "missed", "d": "damaged"}


def load_arm_config(path: Optional[str] = None) -> dict:
    p = Path(path) if path else CONFIG_DIR / "arm.yaml"
    cfg = yaml.safe_load(p.read_text(encoding="utf-8"))
    for k in ("links_m", "joints", "pick"):
        if k not in cfg:
            raise ValueError(f"{p}: missing '{k}'")
    return cfg


def harvest_session(frames: Iterator[tuple[datetime, object, list[Detection]]], picker: Picker,
                    log: AttemptLog, cfg: dict, farm: str, segment: str, max_picks: int,
                    ask_outcome: Optional[Callable[[PickAttempt], None]] = None,
                    give_up_after_frames: int = 15, skip_after_pick: int = 5) -> list[PickAttempt]:
    """Pick open bolls visible from the parked cart until none are left,
    max_picks is reached, or an attempt is aborted (E-stop / dead-man)."""
    p = cfg["pick"]
    attempted: dict[int, int] = {}
    attempts: list[PickAttempt] = []
    empty = 0
    it = iter(frames)
    while len(attempts) < max_picks:
        try:
            _, _, dets = next(it)
        except StopIteration:
            break
        targets = select_targets(dets, picker, attempted, int(p["max_attempts_per_boll"]),
                                 float(p["min_conf"]), float(p["max_range_m"]))
        if not targets:
            empty += 1
            if empty >= give_up_after_frames:
                break
            continue
        empty = 0
        det, _ = targets[0]
        att = picker.pick(det, farm, segment, now=lambda: datetime.now(IST))
        if det.track_id is not None:
            attempted[det.track_id] = attempted.get(det.track_id, 0) + 1
        if ask_outcome is not None and att.result == "completed":
            ask_outcome(att)
        log.write(att)
        attempts.append(att)
        if att.result == "aborted":
            break
        for _ in range(skip_after_pick):            # let the camera see the result, drop stale frames
            if next(it, None) is None:
                break
    return attempts


def workspace_map(picker: Picker, x_range=(0.05, 0.60), z_range=(-0.10, 0.45),
                  step=0.02, y=0.0) -> tuple[list[str], Optional[tuple[float, float]]]:
    """ASCII map (side view, arm base frame) of where a boll can be picked:
    '#' = full pick plan possible (pre point + contact, same approach)."""
    import numpy as np
    xs = np.arange(x_range[0], x_range[1] + 1e-9, step)
    zs = np.arange(z_range[1], z_range[0] - 1e-9, -step)
    rows, hit_x = [], []
    for z in zs:
        line = ""
        for x in xs:
            try:
                picker.plan_base((float(x), y, float(z)))
                line += "#"
                hit_x.append(float(x))
            except Unreachable:
                line += "."
        rows.append(f"z={z:+.2f} m {line}")
    rows.append(f"          x from {x_range[0]:.2f} to {x_range[1]:.2f} m, step {step:.2f} m (forward from the base)")
    return rows, (min(hit_x), max(hit_x)) if hit_x else None


def summarise(attempts: list[PickAttempt]) -> dict:
    done = [a for a in attempts if a.result == "completed"]
    scored = [a for a in done if a.outcome]
    picked = sum(a.outcome == "picked" for a in scored)
    cycles = sorted(a.cycle_s for a in done)
    return {
        "attempts": len(attempts), "completed": len(done),
        "unreachable": sum(a.result == "unreachable" for a in attempts),
        "aborted": sum(a.result == "aborted" for a in attempts),
        "scored": len(scored),
        "success_rate": round(picked / len(scored), 3) if scored else None,
        "cycle_median_s": cycles[len(cycles) // 2] if cycles else None,
    }


def _ask(att: PickAttempt) -> None:
    while True:
        k = input(f"  attempt {att.id}: [p]icked / p[a]rtial / [m]issed / [d]amaged? ").strip().lower()
        if k in OUTCOMES:
            att.outcome = OUTCOMES[k]
            break
    for field in ("lint_left_g", "trash_g"):
        v = input(f"  {field} (grams, Enter to skip): ").strip()
        if v:
            try:
                setattr(att, field, float(v))
            except ValueError:
                print("  not a number, skipped")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Robotic cotton picking (parked cart)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("workspace", help="print where bolls are pickable (no hardware needed)")
    sub.add_parser("plan", help="detect and plan, no motion")
    g = sub.add_parser("goto", help="move the nozzle to a point")
    grp = g.add_mutually_exclusive_group(required=True)
    grp.add_argument("--base", nargs=3, type=float, metavar=("X", "Y", "Z"))
    grp.add_argument("--cam", nargs=3, type=float, metavar=("X", "Y", "Z"))
    r = sub.add_parser("run")
    r.add_argument("--farm", default=None)
    r.add_argument("--segment", required=True, help="row segment the cart is parked at, e.g. R003-S02")
    r.add_argument("--max-picks", type=int, default=10)
    r.add_argument("--confirm", action="store_true", help="score each attempt (E10)")
    r.add_argument("--log", default=str(PACKAGE_DIR / "experiments" / "E10" / "picks.csv"))
    a = ap.parse_args(argv)

    from ..actuators import connect_from_config
    from ..cart import load_cart_config, resolve
    from ..detectors import make_source
    from ..store import Outbox

    arm_cfg, cart_cfg = load_arm_config(), load_cart_config()
    kin = ArmKinematics(arm_cfg)
    if a.cmd == "workspace":
        import numpy as np
        rows, xr = workspace_map(Picker(arm_cfg, kin, HandEye(np.eye(3), np.zeros(3), 0, 0, 0), None))
        print("\n".join(rows))
        print(f"pickable straight ahead: x = {xr[0]:.2f} - {xr[1]:.2f} m" if xr else "nothing pickable: check arm.yaml")
        print("park the cart so open bolls fall inside the '#' zone")
        return 0
    he = HandEye.load()
    if he.rms_m > 0.01:
        print(f"WARNING: calibration RMS {he.rms_m * 1000:.1f} mm > 10 mm - recalibrate", file=sys.stderr)

    if a.cmd == "plan":
        cart_cfg["detector"]["kind"] = "oak"
        picker = Picker(arm_cfg, kin, he, arm=None)
        for n, (_, _, dets) in enumerate(make_source(cart_cfg).frames()):
            ts = select_targets(dets, picker, {}, 1, arm_cfg["pick"]["min_conf"], arm_cfg["pick"]["max_range_m"])
            print(f"frame {n}: {len(dets)} detections, {len(ts)} pickable")
            for d, pl in ts[:3]:
                print(f"   track {d.track_id} conf {d.conf:.2f} base {tuple(round(v, 3) for v in pl.base_xyz)} "
                      f"pitch {pl.pitch_deg} elbow {pl.elbow} -> {pl.contact_deg}")
            if n >= 20:
                return 0
        return 0

    bridge = connect_from_config(cart_cfg, Outbox(resolve(cart_cfg["store"]["db"])))
    import time
    time.sleep(2.5)

    if a.cmd == "goto":
        target = tuple(a.base) if a.base else he.to_base(a.cam)
        try:
            sol, _ = kin.solve(target, arm_cfg["pick"]["preferred_pitch_deg"],
                               arm_cfg["pick"]["pitch_tolerance_deg"])
        except Unreachable as e:
            print(f"unreachable: {e}", file=sys.stderr)
            return 1
        bridge.move(sol.servo_deg, speed_dps=15)
        tip, _ = kin.fk(sol.servo_deg)
        print(f"servo {sol.servo_deg} pitch {sol.pitch_deg} -> nozzle at {tuple(round(v, 3) for v in tip)} m (base frame)")
        print("measure the miss distance with a ruler and record it in experiments/E5/")
        return 0

    cart_cfg["detector"]["kind"] = "oak"
    picker = Picker(arm_cfg, kin, he, bridge)
    log = AttemptLog(a.log, bridge.outbox)
    print("hold the dead-man button; release it to stop")
    bridge.move(home=True, speed_dps=20)
    try:
        atts = harvest_session(make_source(cart_cfg).frames(), picker, log, arm_cfg,
                               a.farm or cart_cfg["farm"], a.segment, a.max_picks,
                               _ask if a.confirm else None)
    finally:
        try:
            bridge.effector(False)
            bridge.move(home=True, speed_dps=20)
        except Exception as e:  # noqa: BLE001
            print(f"could not return home: {e}", file=sys.stderr)
    print(summarise(atts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
