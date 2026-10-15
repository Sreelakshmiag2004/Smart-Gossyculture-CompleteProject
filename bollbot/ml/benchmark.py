"""Measure end-to-end detection speed on the device itself (experiment E2).

Run ON the Raspberry Pi (NCNN fallback) or any machine:
  python -m bollbot.ml.benchmark runs/v1/weights/best_ncnn_model frames/ \
      --out experiments/E2/pi_ncnn_416.json

Each frame is timed from reading the image file to having boxes, so the
number includes pre/post-processing. The first 5 frames are warm-up and
are dropped. OAK-D on-device speed is measured by the edge software
(Module 3), which logs the camera's own frame timestamps.
"""
from __future__ import annotations

import argparse
import json
import platform
import sys
import time
from dataclasses import asdict
from pathlib import Path

from bollbot.core.config import load_ml
from .dataset import IMAGE_EXTS
from .metrics import speed_from_latencies


def main(argv: list[str] | None = None) -> int:
    ml = load_ml()
    ap = argparse.ArgumentParser(description="Per-frame speed benchmark")
    ap.add_argument("model", help=".pt file or exported model folder (e.g. *_ncnn_model)")
    ap.add_argument("frames", help="folder of field images")
    ap.add_argument("--imgsz", type=int, default=ml["train"]["imgsz"])
    ap.add_argument("--n", type=int, default=200, help="frames to time")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    try:
        import cv2
        from ultralytics import YOLO
    except ImportError:
        print("needs ultralytics and opencv: pip install ultralytics", file=sys.stderr)
        return 2

    files = sorted(p for p in Path(a.frames).iterdir() if p.suffix.lower() in IMAGE_EXTS)
    if not files:
        print("no images found", file=sys.stderr)
        return 1
    model = YOLO(a.model, task="detect")
    lat = []
    for i in range(a.n):
        t0 = time.perf_counter()
        img = cv2.imread(str(files[i % len(files)]))
        model.predict(img, imgsz=a.imgsz, verbose=False)
        lat.append(time.perf_counter() - t0)
    res = speed_from_latencies(lat)
    out = {**asdict(res), "model": a.model, "imgsz": a.imgsz,
           "machine": platform.machine(), "node": platform.node()}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, indent=2))
    print(f"{res.fps} FPS, p50 {res.latency_p50_ms} ms, p90 {res.latency_p90_ms} ms -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
