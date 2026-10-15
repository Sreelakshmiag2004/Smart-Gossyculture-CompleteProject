"""Evaluate a trained model on the held-out TEST farm (experiment E1) and
check the spec targets.

  python -m bollbot.ml.evaluate runs/v1/weights/best.pt dataset/data.yaml \
      [--speed-json experiments/E2/speed.json] [--counts-csv experiments/E3/counts.csv]

Writes <run>/eval_test.json: overall and per-class precision, recall,
mAP@50, mAP@50-95, the confusion matrix (rows = TRUE class), the top
confusions, rare classes and the target check. The dashboard's 'Model &
data quality' screen and the report read numbers ONLY from this file.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from bollbot.core.config import load_ml
from bollbot.core.models import CLASSES
from .metrics import (check_targets, counting_errors, load_count_csv, normalise_rows,
                      rare_classes, top_confusions)


def extract_metrics(m, names: list[str]) -> dict:
    """Turn an Ultralytics DetMetrics object into plain numbers.

    Ultralytics stores the confusion matrix as matrix[predicted][true], with
    an extra last row/column for background. It is transposed here so that
    rows are TRUE classes, which is how the report reads it.
    """
    model_names = getattr(m, "names", None)
    if model_names is not None:
        got = list(model_names.values()) if isinstance(model_names, dict) else list(model_names)
        if got != list(names):
            # A model trained with another class order would be mislabelled (QA bug 14).
            raise ValueError(f"model classes {got} differ from expected {list(names)}")
    per_class = {}
    for i, cid in enumerate(m.ap_class_index):
        per_class[names[int(cid)]] = {
            "precision": round(float(m.box.p[i]), 4), "recall": round(float(m.box.r[i]), 4),
            "map50": round(float(m.box.ap50[i]), 4), "map50_95": round(float(m.box.ap[i]), 4)}
    raw = [[float(v) for v in row] for row in m.confusion_matrix.matrix]
    true_rows = [list(col) for col in zip(*raw)]          # transpose: rows = true
    labels = list(names) + ["background"]
    return {
        "map50": round(float(m.box.map50), 4), "map50_95": round(float(m.box.map), 4),
        "precision": round(float(m.box.mp), 4), "recall": round(float(m.box.mr), 4),
        "per_class": per_class,
        "confusion": {"labels": labels, "counts_true_rows": true_rows,
                      "normalised_true_rows": normalise_rows(true_rows)},
        "top_confusions": [{"true": t, "pred": p, "share": s}
                           for t, p, s in top_confusions(true_rows, labels)],
    }


def main(argv: list[str] | None = None) -> int:
    ml = load_ml()
    ap = argparse.ArgumentParser(description="Evaluate on the test farm")
    ap.add_argument("weights")
    ap.add_argument("data_yaml")
    ap.add_argument("--imgsz", type=int, default=ml["train"]["imgsz"])
    ap.add_argument("--split", default="test", choices=["val", "test"])
    ap.add_argument("--speed-json", help="output of bollbot.ml.benchmark (E2)")
    ap.add_argument("--counts-csv", help="segment,cls,true,pred rows (E3)")
    a = ap.parse_args(argv)

    try:
        from ultralytics import YOLO
    except ImportError:
        print("ultralytics is not installed: pip install ultralytics", file=sys.stderr)
        return 2

    weights = Path(a.weights)
    run_dir = weights.parent.parent
    m = YOLO(str(weights)).val(data=a.data_yaml, split=a.split, imgsz=a.imgsz, plots=True,
                               project=str(run_dir), name=f"eval_{a.split}", exist_ok=True)
    result = {"split": a.split, "weights": str(weights), **extract_metrics(m, list(CLASSES))}

    manifest = Path(a.data_yaml).parent / "manifest.json"
    if manifest.exists():
        train_inst = json.loads(manifest.read_text(encoding="utf-8"))["splits"]["train"]["instances"]
        result["rare_classes_alert_only"] = rare_classes(
            train_inst, ml["rare_class"]["min_train_instances"])
    if a.speed_json:
        result["fps"] = json.loads(Path(a.speed_json).read_text(encoding="utf-8"))["fps"]
    if a.counts_csv:
        counts = counting_errors(load_count_csv(a.counts_csv))
        result["counting"] = [asdict(c) for c in counts]
        open_c = next((c for c in counts if c.cls == "boll_open"), None)
        result["count_mape"] = open_c.mape if open_c else None

    targets = check_targets(result, ml["targets"]) if a.split == "test" else []
    result["targets"] = [asdict(t) for t in targets]
    out = run_dir / f"eval_{a.split}.json"
    out.write_text(json.dumps(result, indent=2), encoding="utf-8")

    print(f"mAP@50 {result['map50']:.3f}  mAP@50-95 {result['map50_95']:.3f}")
    for c, v in result["per_class"].items():
        print(f"  {c:16s} P {v['precision']:.3f}  R {v['recall']:.3f}  mAP50 {v['map50']:.3f}")
    for t in targets:
        mark = {True: "MET", False: "MISSED", None: "not measured"}[t.met]
        print(f"  target {t.kpi}: {t.value} ({t.target}) -> {mark}")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
