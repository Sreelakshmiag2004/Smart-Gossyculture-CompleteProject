"""Camera -> arm-base calibration (spec Section 7, experiment E5).

The camera is fixed on the cart mast and the arm base is fixed on the cart,
so one rigid transform maps camera coordinates to arm coordinates. It is
found from point pairs: the arm moves its nozzle (with a small ArUco tag on
it) to N poses; forward kinematics gives each point in the ARM frame, and
the stereo camera measures the same point in the CAMERA frame. The best-fit
rotation + translation (Kabsch/SVD) is saved with its residual error.

  python -m bollbot.edge.arm.handeye collect     # moves the arm through calibration_poses
  python -m bollbot.edge.arm.handeye show        # print the saved calibration
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional, Sequence

import numpy as np

from bollbot.core.config import CONFIG_DIR

DEFAULT_PATH = CONFIG_DIR / "handeye.json"
MAX_GOOD_RMS_M = 0.01      # >1 cm residual: recalibrate before picking


class CalibrationError(ValueError):
    pass


@dataclass
class HandEye:
    R: np.ndarray            # 3x3, camera -> base
    t: np.ndarray            # 3,
    rms_m: float
    max_err_m: float
    n: int
    created: str = ""

    def to_base(self, p_cam: Sequence[float]) -> tuple[float, float, float]:
        v = self.R @ np.asarray(p_cam, dtype=float) + self.t
        return float(v[0]), float(v[1]), float(v[2])

    def save(self, path: str | Path = DEFAULT_PATH) -> None:
        Path(path).write_text(json.dumps({
            "R": self.R.tolist(), "t": self.t.tolist(), "rms_m": self.rms_m,
            "max_err_m": self.max_err_m, "n": self.n, "created": self.created}, indent=2),
            encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path = DEFAULT_PATH) -> "HandEye":
        p = Path(path)
        if not p.exists():
            raise CalibrationError(f"no calibration at {p}: run 'python -m bollbot.edge.arm.handeye collect'")
        d = json.loads(p.read_text(encoding="utf-8"))
        R = np.asarray(d["R"], dtype=float)
        if R.shape != (3, 3) or not np.allclose(R @ R.T, np.eye(3), atol=1e-6) \
                or not np.isclose(np.linalg.det(R), 1.0, atol=1e-6):
            raise CalibrationError(f"{p}: R is not a rotation matrix")
        return cls(R, np.asarray(d["t"], dtype=float), float(d["rms_m"]),
                   float(d["max_err_m"]), int(d["n"]), d.get("created", ""))


def fit(p_cam: Sequence[Sequence[float]], p_base: Sequence[Sequence[float]]) -> HandEye:
    """Least-squares rigid transform p_base ~ R p_cam + t (Kabsch, no scaling).

    A reflection is never accepted: if the best fit needs one, the camera
    coordinates use a different handedness than assumed, and the residual
    will be large, which is reported rather than hidden.
    """
    A = np.asarray(p_cam, dtype=float)
    B = np.asarray(p_base, dtype=float)
    if A.shape != B.shape or A.ndim != 2 or A.shape[1] != 3:
        raise CalibrationError("need two N x 3 point lists of the same length")
    if len(A) < 4:
        raise CalibrationError(f"need at least 4 point pairs, got {len(A)}")
    ca, cb = A.mean(axis=0), B.mean(axis=0)
    A0, B0 = A - ca, B - cb
    if np.linalg.matrix_rank(A0, tol=1e-4) < 2 or np.linalg.matrix_rank(B0, tol=1e-4) < 2:
        raise CalibrationError("points are (nearly) collinear: spread the calibration poses")
    U, _, Vt = np.linalg.svd(A0.T @ B0)
    D = np.diag([1.0, 1.0, np.sign(np.linalg.det(Vt.T @ U.T)) or 1.0])
    R = Vt.T @ D @ U.T
    t = cb - R @ ca
    err = np.linalg.norm((A @ R.T + t) - B, axis=1)
    return HandEye(R, t, float(np.sqrt(np.mean(err ** 2))), float(err.max()), len(A),
                   datetime.now().isoformat(timespec="seconds"))


class OakTipLocator:
    """Finds the nozzle's ArUco tag in the OAK-D colour image and measures its
    3D position with the camera's own SpatialLocationCalculator, so the
    coordinates follow EXACTLY the same convention as the spatial YOLO
    detections used for picking. Written for DepthAI v2; verify on hardware.
    """

    def __init__(self, tag_id: int = 0, dictionary: str = "DICT_4X4_50", roi_px: int = 6):
        import cv2
        import depthai as dai
        self.dai, self.cv2, self.tag_id, self.roi_px = dai, cv2, tag_id, roi_px
        d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, dictionary))
        self.det = cv2.aruco.ArucoDetector(d, cv2.aruco.DetectorParameters())
        p = dai.Pipeline()
        cam = p.create(dai.node.ColorCamera)
        cam.setBoardSocket(dai.CameraBoardSocket.CAM_A)
        cam.setResolution(dai.ColorCameraProperties.SensorResolution.THE_1080_P)
        cam.setPreviewSize(640, 360)
        cam.setInterleaved(False)
        left, right = p.create(dai.node.MonoCamera), p.create(dai.node.MonoCamera)
        left.setBoardSocket(dai.CameraBoardSocket.CAM_B)
        right.setBoardSocket(dai.CameraBoardSocket.CAM_C)
        for m in (left, right):
            m.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)
        stereo = p.create(dai.node.StereoDepth)
        stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.HIGH_DENSITY)
        stereo.setDepthAlign(dai.CameraBoardSocket.CAM_A)
        stereo.setOutputSize(640, 360)
        left.out.link(stereo.left)
        right.out.link(stereo.right)
        slc = p.create(dai.node.SpatialLocationCalculator)
        slc.inputConfig.setWaitForMessage(False)
        slc.initialConfig.addROI(self._roi_cfg(0.5, 0.5, 0.01))
        stereo.depth.link(slc.inputDepth)
        for name, out in (("rgb", cam.preview), ("spatial", slc.out)):
            x = p.create(dai.node.XLinkOut)
            x.setStreamName(name)
            out.link(x.input)
        xin = p.create(dai.node.XLinkIn)
        xin.setStreamName("slc_cfg")
        xin.out.link(slc.inputConfig)
        self.dev = dai.Device(p)
        self.q_rgb = self.dev.getOutputQueue("rgb", 4, False)
        self.q_sp = self.dev.getOutputQueue("spatial", 4, False)
        self.q_cfg = self.dev.getInputQueue("slc_cfg")

    def _roi_cfg(self, u: float, v: float, half: float):
        dai = self.dai
        c = dai.SpatialLocationCalculatorConfigData()
        c.depthThresholds.lowerThreshold = 150
        c.depthThresholds.upperThreshold = 2500
        c.calculationAlgorithm = dai.SpatialLocationCalculatorAlgorithm.MEDIAN
        c.roi = dai.Rect(dai.Point2f(u - half, v - half), dai.Point2f(u + half, v + half))
        return c

    def locate(self, tries: int = 30) -> Optional[tuple[float, float, float]]:
        """Median of several measurements of the tag centre, metres, or None."""
        pts = []
        for _ in range(tries):
            frame = self.q_rgb.get().getCvFrame()
            corners, ids, _ = self.det.detectMarkers(self.cv2.cvtColor(frame, self.cv2.COLOR_BGR2GRAY))
            if ids is None or self.tag_id not in ids.ravel():
                continue
            c = corners[list(ids.ravel()).index(self.tag_id)][0].mean(axis=0)
            h, w = frame.shape[:2]
            msg = self.dai.SpatialLocationCalculatorConfig()
            msg.addROI(self._roi_cfg(c[0] / w, c[1] / h, self.roi_px / w))
            self.q_cfg.send(msg)
            self.q_sp.get()                                   # result for the old ROI
            loc = self.q_sp.get().getSpatialLocations()[0].spatialCoordinates
            if loc.z > 0:
                pts.append((loc.x / 1000.0, loc.y / 1000.0, loc.z / 1000.0))
            if len(pts) >= 5:
                break
        return tuple(float(v) for v in np.median(np.asarray(pts), axis=0)) if pts else None

    def close(self) -> None:
        self.dev.close()


def collect(arm_cfg: dict, bridge, locator, settle_s: float = 1.0) -> HandEye:
    """Move through calibration_poses, pair FK points with camera points, fit."""
    import time
    from .kinematics import ArmKinematics
    kin = ArmKinematics(arm_cfg)
    cam_pts, base_pts = [], []
    for pose in arm_cfg["calibration_poses"]:
        bridge.move(pose, speed_dps=20)
        time.sleep(settle_s)
        p = locator.locate()
        if p is None:
            print(f"pose {pose}: tag not seen, skipped")
            continue
        cam_pts.append(p)
        base_pts.append(kin.fk(pose)[0])
        print(f"pose {pose}: camera {tuple(round(v, 3) for v in p)}")
    bridge.move(home=True, speed_dps=20)
    return fit(cam_pts, base_pts)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Camera -> arm calibration")
    ap.add_argument("cmd", choices=["collect", "show"])
    a = ap.parse_args(argv)
    if a.cmd == "show":
        he = HandEye.load()
        print(f"{he.n} points, RMS {he.rms_m * 1000:.1f} mm, max {he.max_err_m * 1000:.1f} mm, {he.created}")
        return 0
    import yaml
    from ..actuators import connect_from_config
    from ..cart import load_cart_config
    arm_cfg = yaml.safe_load((CONFIG_DIR / "arm.yaml").read_text(encoding="utf-8"))
    bridge = connect_from_config(load_cart_config())
    locator = OakTipLocator()
    try:
        he = collect(arm_cfg, bridge, locator)
    finally:
        locator.close()
    he.save()
    verdict = "OK" if he.rms_m <= MAX_GOOD_RMS_M else "TOO HIGH: check link lengths, zero angles, tag mounting"
    print(f"saved {DEFAULT_PATH}: {he.n} points, RMS {he.rms_m * 1000:.1f} mm "
          f"(max {he.max_err_m * 1000:.1f} mm) -> {verdict}")
    return 0 if he.rms_m <= MAX_GOOD_RMS_M else 1


if __name__ == "__main__":
    sys.exit(main())
