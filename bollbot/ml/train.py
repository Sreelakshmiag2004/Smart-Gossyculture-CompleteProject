"""Train the BollBot detector (experiment E1). Run on Colab or a GPU machine.

  pip install ultralytics
  python -m bollbot.ml.train dataset/data.yaml --name v1
  python -m bollbot.ml.train dataset/data.yaml --name v1-512 --imgsz 512   # ablation

Writes runs/<name>/ (Ultralytics output) and runs/<name>/run_meta.json,
which records exactly what was trained on, so every reported number can be
traced back to a dataset and a configuration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path

from bollbot.core.config import load_ml


def _md5(path: Path) -> str | None:
    return hashlib.md5(path.read_bytes()).hexdigest() if path.exists() else None


def main(argv: list[str] | None = None) -> int:
    cfg = load_ml()["train"]
    ap = argparse.ArgumentParser(description="Train YOLOv8 on the BollBot dataset")
    ap.add_argument("data_yaml")
    ap.add_argument("--name", required=True, help="run name, e.g. v1")
    ap.add_argument("--imgsz", type=int, default=cfg["imgsz"])
    ap.add_argument("--epochs", type=int, default=cfg["epochs"])
    ap.add_argument("--batch", type=int, default=cfg["batch"])
    ap.add_argument("--model", default=cfg["base_model"])
    ap.add_argument("--project", default="runs")
    a = ap.parse_args(argv)

    try:
        import ultralytics
        from ultralytics import YOLO
    except ImportError:
        print("ultralytics is not installed: pip install ultralytics", file=sys.stderr)
        return 2

    data_yaml = Path(a.data_yaml)
    manifest = data_yaml.parent / "manifest.json"
    # An absolute project path stops Ultralytics from nesting a relative one
    # under its own runs_dir, so runs/<name>/weights/best.pt is where the
    # README says. An existing name is refused because Ultralytics would
    # silently rename the run (v1 -> v1-2) and later steps would evaluate
    # the OLD weights (QA bug 4).
    project = Path(a.project).resolve()
    if (project / a.name).exists():
        print(f"{project / a.name} already exists; choose a new --name", file=sys.stderr)
        return 1
    model = YOLO(a.model)
    model.train(data=str(data_yaml), imgsz=a.imgsz, epochs=a.epochs,
                patience=cfg["patience"], batch=a.batch, seed=cfg["seed"],
                deterministic=True, project=str(project), name=a.name, exist_ok=False)

    run_dir = Path(model.trainer.save_dir)
    if run_dir.resolve() != (project / a.name).resolve():
        print(f"WARNING: Ultralytics saved to {run_dir}, not {project / a.name}", file=sys.stderr)
    meta = {
        "run": a.name,
        "finished_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "base_model": a.model, "imgsz": a.imgsz, "epochs": a.epochs, "batch": a.batch,
        "patience": cfg["patience"], "seed": cfg["seed"],
        "data_yaml": str(data_yaml.resolve()),
        "dataset_manifest_md5": _md5(manifest),
        "split_assignment": json.loads(manifest.read_text(encoding="utf-8"))["assignment"] if manifest.exists() else None,
        "ultralytics": ultralytics.__version__, "python": platform.python_version(),
        "best_weights": str(run_dir / "weights" / "best.pt"),
    }
    (run_dir / "run_meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"done: {run_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
