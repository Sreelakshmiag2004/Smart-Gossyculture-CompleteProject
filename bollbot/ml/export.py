"""Export trained weights for each device (spec Section 6).

  python -m bollbot.ml.export runs/v1/weights/best.pt dataset/data.yaml

  ncnn      -> Raspberry Pi 4 fallback (best_ncnn_model/)
  tflite    -> phone-capture mode, int8 (calibrated on the dataset)
  openvino  -> intermediate for the OAK-D Lite

OAK-D Lite: the camera needs a .blob plus a YOLO decoding config. The
simplest reliable route is Luxonis' converter at https://tools.luxonis.com:
upload best.pt, choose YOLOv8 and input size 416, download the .zip
(.blob + .json), and put both in edge/models/. Verify the current steps on
the Luxonis documentation, since their tooling changes between releases.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from bollbot.core.config import load_ml


def main(argv: list[str] | None = None) -> int:
    ml = load_ml()
    ap = argparse.ArgumentParser(description="Export weights for edge devices")
    ap.add_argument("weights")
    ap.add_argument("data_yaml", help="needed for int8 calibration")
    ap.add_argument("--formats", nargs="+", default=ml["export"]["formats"])
    ap.add_argument("--imgsz", type=int, default=ml["train"]["imgsz"])
    a = ap.parse_args(argv)
    try:
        from ultralytics import YOLO
    except ImportError:
        print("ultralytics is not installed: pip install ultralytics", file=sys.stderr)
        return 2

    model = YOLO(a.weights)
    outputs = {}
    for fmt in a.formats:
        kwargs = {"format": fmt, "imgsz": a.imgsz}
        if fmt == "tflite" and ml["export"]["tflite_int8"]:
            kwargs.update(int8=True, data=a.data_yaml)
        path = model.export(**kwargs)
        outputs[fmt] = str(path)
        print(f"{fmt:9s} -> {path}")
    (Path(a.weights).parent / "exports.json").write_text(json.dumps(outputs, indent=2))
    print("OAK-D: convert best.pt at https://tools.luxonis.com (YOLOv8, 416) -> edge/models/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
