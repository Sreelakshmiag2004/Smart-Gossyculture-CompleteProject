"""E1 detector quality, E2 edge speed, E3 counting accuracy (spec Section 13).

E1 reads eval_test.json written by `python -m bollbot.ml.evaluate` (copy it into experiments/E1/,
with the dataset's manifest.json). E2 reads one or more speed*.json from `bollbot.ml.benchmark`.
E3 reads counts.csv (segment, cls, true, pred[, mode]) and optionally scan_times.csv.
"""
from __future__ import annotations

import json
import statistics
from pathlib import Path
from typing import Optional

from bollbot.core.models import CLASSES
from bollbot.ml.metrics import counting_errors

from .common import (DataError, ExperimentResult, check_sample, figure_path, load_targets, new_result, num,
                     pyplot, read_csv, save, set_kpi)


# ----------------------------------------------------------------------------- E1
def e1(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E1"]
    res = new_result("E1", targets)
    path = data_dir / "eval_test.json"
    if not path.exists():
        res.notes.append("No data yet: copy runs/<name>/eval_test.json (from bollbot.ml.evaluate on the TEST farm) here.")
        return res
    ev = json.loads(path.read_text(encoding="utf-8"))
    if ev.get("split") not in (None, "test"):
        raise DataError(f"{path.name} is from the '{ev.get('split')}' split; E1 is measured on the held-out TEST farm")
    per = ev.get("per_class") or {}
    set_kpi(res, "map50", ev.get("map50"))
    set_kpi(res, "map50_95", ev.get("map50_95"))
    if "boll_open" in per:
        set_kpi(res, "open_boll_recall", per["boll_open"].get("recall"))
    else:
        res.kpi("open_boll_recall").note = "no boll_open instances in the test split"
    res.tables["per_class"] = [
        {"class": c, "precision": per[c].get("precision"), "recall": per[c].get("recall"), "mAP@50": per[c].get("map50")}
        for c in CLASSES if c in per
    ]
    if ev.get("rare_classes_alert_only"):
        res.notes.append(f"Classes with too few training instances (shown as alert-only): {', '.join(ev['rare_classes_alert_only'])}.")
    manifest = data_dir / "manifest.json"
    if manifest.exists():
        m = json.loads(manifest.read_text(encoding="utf-8"))
        images = sum(s.get("images", 0) for s in m.get("splits", {}).values())
        res.n = images
        check_sample(res, images, t["min_images"], "images")
        inst = {}
        for s in m.get("splits", {}).values():
            for c, k in (s.get("instances") or {}).items():
                inst[c] = inst.get(c, 0) + k
        thin = [c for c in CLASSES[:5] if inst.get(c, 0) < t["min_instances_classes_0_4"]]
        if thin:
            res.notes.append(f"Classes 0-4 below {t['min_instances_classes_0_4']} instances: {', '.join(thin)}.")
    else:
        res.notes.append("manifest.json not found: dataset size not checked.")
    if res.tables["per_class"]:
        plt = pyplot()
        rows = res.tables["per_class"]
        fig, ax = plt.subplots(figsize=(8, 4))
        x = range(len(rows))
        ax.bar([i - 0.2 for i in x], [r["precision"] or 0 for r in rows], 0.4, label="precision")
        ax.bar([i + 0.2 for i in x], [r["recall"] or 0 for r in rows], 0.4, label="recall")
        ax.axhline(t["kpis"]["open_boll_recall"]["target"], ls="--", c="grey", lw=1, label="open-boll recall target")
        ax.set_xticks(list(x), [r["class"] for r in rows], rotation=30, ha="right")
        ax.set_ylim(0, 1)
        ax.set_title("E1 - per-class precision and recall (test farm)")
        ax.legend()
        save(fig, figure_path(out_dir, "E1", "per_class"), res)
    return res


# ----------------------------------------------------------------------------- E2
def e2(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E2"]
    res = new_result("E2", targets)
    files = sorted(data_dir.glob("speed*.json"))
    if not files:
        res.notes.append("No data yet: run bollbot.ml.benchmark --out experiments/E2/speed_run1.json (3 runs).")
        return res
    runs = []
    for f in files:
        d = json.loads(f.read_text(encoding="utf-8"))
        runs.append({"run": f.stem, "machine": d.get("machine"), "model": Path(str(d.get("model", ""))).name,
                     "fps": d["fps"], "p50_ms": d.get("latency_p50_ms"), "p90_ms": d.get("latency_p90_ms"), "frames": d.get("frames")})
    res.tables["runs"] = runs
    res.n = len(runs)
    set_kpi(res, "fps", statistics.median(r["fps"] for r in runs), f"median of {len(runs)} run(s); slowest {min(r['fps'] for r in runs)}")
    check_sample(res, len(runs), t["min_runs"], "benchmark runs")
    return res


# ----------------------------------------------------------------------------- E3
def e3(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E3"]
    res = new_result("E3", targets)
    path = data_dir / "counts.csv"
    if not path.exists():
        res.notes.append("No data yet: fill counts.csv (one row per segment and class; see counts_template.csv).")
    else:
        rows = read_csv(path, ["segment", "cls", "true", "pred"])
        for r in rows:
            if r["cls"] not in CLASSES:
                raise DataError(f"{path.name}: unknown class {r['cls']!r}")
            r["mode"] = (r.get("mode") or "cart").lower()
            if r["mode"] not in ("cart", "phone"):
                raise DataError(f"{path.name}: mode must be cart or phone, got {r['mode']!r}")
        table = []
        for mode in ("cart", "phone"):
            mrows = [r for r in rows if r["mode"] == mode]
            if not mrows:
                continue
            for c in counting_errors(mrows):
                table.append({"mode": mode, "class": c.cls, "segments": c.segments, "MAE (bolls)": c.mae,
                              "MAPE %": c.mape, "true total": c.total_true, "counted total": c.total_pred, "bias %": c.bias_pct})
            open_c = next((c for c in counting_errors(mrows) if c.cls == "boll_open"), None)
            set_kpi(res, f"{mode}_mape_open", open_c.mape if open_c else None)
        res.tables["counting"] = table
        cart_segments = {r["segment"] for r in rows if r["mode"] == "cart"}
        res.n = len(cart_segments)
        check_sample(res, len(cart_segments), t["min_segments"], "cart segments")
        open_rows = [r for r in rows if r["cls"] == "boll_open"]
        if open_rows:
            plt = pyplot()
            fig, ax = plt.subplots(figsize=(5, 5))
            for mode, marker in (("cart", "o"), ("phone", "^")):
                pts = [(int(r["true"]), int(r["pred"])) for r in open_rows if r["mode"] == mode]
                if pts:
                    ax.scatter([p[0] for p in pts], [p[1] for p in pts], marker=marker, label=mode, alpha=0.7)
            top = max(max(int(r["true"]), int(r["pred"])) for r in open_rows) * 1.1 + 1
            ax.plot([0, top], [0, top], "k--", lw=1, label="perfect")
            ax.set_xlabel("hand count (open bolls)")
            ax.set_ylabel("system count")
            ax.set_title("E3 - open-boll counts per segment")
            ax.legend()
            save(fig, figure_path(out_dir, "E3", "counts"), res)
    times = data_dir / "scan_times.csv"
    if times.exists():
        rows = read_csv(times, ["plot", "acres", "minutes"])
        per_acre = [num(r, "minutes", times.name) / num(r, "acres", times.name) for r in rows]
        res.tables["scan_times"] = [{"plot": r["plot"], "acres": r["acres"], "minutes": r["minutes"], "min/acre": round(v, 1)} for r, v in zip(rows, per_acre)]
        set_kpi(res, "scan_min_per_acre", statistics.mean(per_acre), f"mean of {len(per_acre)} plot(s)")
    return res
