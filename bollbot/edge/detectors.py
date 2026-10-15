"""Frame sources that yield (timestamp, frame, tracked detections).

UltralyticsTracker - USB camera, video file or folder; YOLOv8 (.pt or NCNN)
                     + ByteTrack, all on the Pi/laptop. Also used to replay
                     recorded field videos for experiments.
OakTracker         - OAK-D Lite: YOLOv8 + stereo depth + object tracker run
                     ON the camera; the Pi only receives results.

The OAK code targets the DepthAI v2 API (pip install "depthai<3"). DepthAI
v3 changed the pipeline API; check the installed version on the Pi and the
Luxonis examples before the first field test.
"""
from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterator

from bollbot.core.models import CLASSES
from bollbot.core.rules import IST
from .counting import Detection

Frame = tuple[datetime, "object", list[Detection]]   # (ts, BGR ndarray, detections)


def now_ist() -> datetime:
    return datetime.now(IST)


class UltralyticsTracker:
    def __init__(self, model_path: str, source: str | int, imgsz: int = 416,
                 conf: float = 0.35, clock: Callable[[], datetime] = now_ist):
        import cv2
        from ultralytics import YOLO
        self._cv2 = cv2
        self.model = YOLO(model_path, task="detect")
        names = list(self.model.names.values()) if isinstance(self.model.names, dict) \
            else list(self.model.names)
        if names != list(CLASSES):
            raise ValueError(f"model classes {names} differ from {list(CLASSES)}")
        self.source = int(source) if str(source).isdigit() else source
        self.imgsz, self.conf, self.clock = imgsz, conf, clock

    def frames(self) -> Iterator[Frame]:
        cap = self._cv2.VideoCapture(self.source)
        if not cap.isOpened():
            raise RuntimeError(f"cannot open video source {self.source!r}")
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    return
                r = self.model.track(frame, persist=True, tracker="bytetrack.yaml",
                                     imgsz=self.imgsz, conf=self.conf, verbose=False)[0]
                yield self.clock(), frame, self._to_dets(r.boxes)
        finally:
            cap.release()

    @staticmethod
    def _to_dets(boxes) -> list[Detection]:
        if boxes is None or len(boxes) == 0:
            return []
        ids = boxes.id.int().tolist() if boxes.id is not None else [None] * len(boxes)
        return [Detection(int(c), float(p), tuple(map(float, xy)), tid)
                for c, p, xy, tid in zip(boxes.cls.int().tolist(), boxes.conf.tolist(),
                                         boxes.xyxy.tolist(), ids)]


class OakTracker:
    """YOLOv8 spatial detection + ObjectTracker on the OAK-D Lite (DepthAI v2)."""

    def __init__(self, blob: str, config_json: str, imgsz: int = 416, conf: float = 0.35,
                 fps: int = 10, clock: Callable[[], datetime] = now_ist):
        import depthai as dai
        self.dai, self.clock, self.imgsz = dai, clock, imgsz
        meta = json.loads(Path(config_json).read_text(encoding="utf-8"))
        nn_meta = meta.get("nn_config", {}).get("NN_specific_metadata", {})
        labels = meta.get("mappings", {}).get("labels")
        if labels and list(labels) != list(CLASSES):
            raise ValueError(f"blob labels {labels} differ from {list(CLASSES)}")

        p = dai.Pipeline()
        cam = p.create(dai.node.ColorCamera)
        cam.setBoardSocket(dai.CameraBoardSocket.CAM_A)
        cam.setResolution(dai.ColorCameraProperties.SensorResolution.THE_1080_P)
        cam.setPreviewSize(imgsz, imgsz)
        cam.setInterleaved(False)
        cam.setColorOrder(dai.ColorCameraProperties.ColorOrder.BGR)
        cam.setFps(fps)

        left, right = p.create(dai.node.MonoCamera), p.create(dai.node.MonoCamera)
        for mono, sock in ((left, dai.CameraBoardSocket.CAM_B), (right, dai.CameraBoardSocket.CAM_C)):
            mono.setBoardSocket(sock)
            mono.setResolution(dai.MonoCameraProperties.SensorResolution.THE_400_P)
            mono.setFps(fps)
        stereo = p.create(dai.node.StereoDepth)
        stereo.setDefaultProfilePreset(dai.node.StereoDepth.PresetMode.HIGH_DENSITY)
        stereo.setDepthAlign(dai.CameraBoardSocket.CAM_A)
        stereo.setOutputSize(imgsz, imgsz)
        left.out.link(stereo.left)
        right.out.link(stereo.right)

        nn = p.create(dai.node.YoloSpatialDetectionNetwork)
        nn.setBlobPath(blob)
        nn.setConfidenceThreshold(conf)
        nn.setNumClasses(len(CLASSES))
        nn.setCoordinateSize(nn_meta.get("coordinates", 4))
        nn.setAnchors(nn_meta.get("anchors", []))
        nn.setAnchorMasks(nn_meta.get("anchor_masks", {}))
        nn.setIouThreshold(nn_meta.get("iou_threshold", 0.5))
        nn.setBoundingBoxScaleFactor(0.5)       # depth averaged over the box centre
        nn.setDepthLowerThreshold(200)           # mm
        nn.setDepthUpperThreshold(2500)          # mm: ignore the next row
        cam.preview.link(nn.input)
        stereo.depth.link(nn.inputDepth)

        trk = p.create(dai.node.ObjectTracker)
        trk.setDetectionLabelsToTrack(list(range(len(CLASSES))))
        trk.setTrackerType(dai.TrackerType.ZERO_TERM_COLOR_HISTOGRAM)
        trk.setTrackerIdAssignmentPolicy(dai.TrackerIdAssignmentPolicy.UNIQUE_ID)
        nn.passthrough.link(trk.inputTrackerFrame)
        nn.passthrough.link(trk.inputDetectionFrame)
        nn.out.link(trk.inputDetections)

        for name, out in (("frame", trk.passthroughTrackerFrame), ("tracklets", trk.out)):
            x = p.create(dai.node.XLinkOut)
            x.setStreamName(name)
            out.link(x.input)
        self.pipeline = p

    def frames(self) -> Iterator[Frame]:
        dai = self.dai
        with dai.Device(self.pipeline) as dev:
            q_frame = dev.getOutputQueue("frame", maxSize=4, blocking=False)
            q_trk = dev.getOutputQueue("tracklets", maxSize=4, blocking=False)
            while True:
                fr, tl = q_frame.get(), q_trk.get()
                frame = fr.getCvFrame()
                h, w = frame.shape[:2]
                dets = []
                for t in tl.tracklets:
                    if t.status not in (dai.Tracklet.TrackingStatus.NEW,
                                        dai.Tracklet.TrackingStatus.TRACKED):
                        continue
                    roi = t.roi.denormalize(w, h)
                    tl_pt, br_pt = roi.topLeft(), roi.bottomRight()
                    sc = t.spatialCoordinates
                    dets.append(Detection(
                        int(t.label), float(t.srcImgDetection.confidence),
                        (tl_pt.x, tl_pt.y, br_pt.x, br_pt.y), int(t.id),
                        (sc.x / 1000.0, sc.y / 1000.0, sc.z / 1000.0)))
                yield self.clock(), frame, dets


class ScriptedSource:
    """Replays a fixed list of frames: for tests and dry runs without a camera."""

    def __init__(self, frames: list[Frame]):
        self._frames = frames

    def frames(self) -> Iterator[Frame]:
        yield from self._frames


def make_source(cfg: dict, source: str | int | None = None):
    d = cfg["detector"]
    if d["kind"] == "oak":
        return OakTracker(d["oak_blob"], d["oak_config"], d["imgsz"], d["conf"], d.get("fps", 10))
    if d["kind"] == "ultralytics":
        return UltralyticsTracker(d["model"], 0 if source is None else source, d["imgsz"], d["conf"])
    raise ValueError(f"unknown detector kind {d['kind']!r}")


def fps_meter(window: int = 50) -> Callable[[], float]:
    """Return a function that, called once per frame, gives the recent FPS."""
    stamps: list[float] = []

    def tick() -> float:
        stamps.append(time.monotonic())
        if len(stamps) > window:
            stamps.pop(0)
        if len(stamps) < 2:
            return 0.0
        return round((len(stamps) - 1) / (stamps[-1] - stamps[0]), 2) if stamps[-1] > stamps[0] else 0.0

    return tick
