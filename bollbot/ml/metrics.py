"""Pure metric functions for experiments E1 (detector), E2 (speed) and
E3 (counting). No ML library needed, so they are unit-tested.
"""
from __future__ import annotations

import csv
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from bollbot.core.models import CLASSES


# ----------------------------------------------------------------- targets
@dataclass
class TargetResult:
    kpi: str
    value: float | None
    target: str
    met: bool | None          # None = not measured


def check_targets(metrics: dict, targets: dict) -> list[TargetResult]:
    """metrics: {'map50': float, 'per_class': {cls: {'recall': ...}}, 'fps': ..., 'count_mape': ...}"""
    out = []

    def add(kpi, value, op, limit):
        if value is None:
            out.append(TargetResult(kpi, None, f"{op} {limit}", None))
        else:
            met = value >= limit if op == ">=" else value <= limit
            out.append(TargetResult(kpi, round(value, 4), f"{op} {limit}", met))

    add("mAP@50 (test farm)", metrics.get("map50"), ">=", targets["map50_min"])
    limit = targets["open_boll_recall_min"]
    if "per_class" in metrics and "boll_open" not in metrics["per_class"]:
        # Evaluation ran but the test farm had no open bolls: that is a
        # failed check, not 'not measured' (QA bug 14).
        out.append(TargetResult("boll_open recall", None,
                                f">= {limit} (no boll_open in test split)", False))
    else:
        open_r = metrics.get("per_class", {}).get("boll_open", {}).get("recall")
        add("boll_open recall", open_r, ">=", limit)
    add("FPS on edge", metrics.get("fps"), ">=", targets["fps_min"])
    add("counting MAPE %", metrics.get("count_mape"), "<=", targets["count_mape_max_pct"])
    return out


def rare_classes(train_instances: dict[str, int], min_instances: int) -> list[str]:
    """Classes too rare to trust: shown as alert-only with human confirmation."""
    return [c for c in CLASSES if train_instances.get(c, 0) < min_instances]


# -------------------------------------------------------- confusion matrix
def normalise_rows(matrix: Sequence[Sequence[float]]) -> list[list[float]]:
    """Row-normalise (each true class sums to 1). Empty rows stay zero."""
    out = []
    for row in matrix:
        s = sum(row)
        out.append([round(v / s, 4) if s else 0.0 for v in row])
    return out


def top_confusions(matrix: Sequence[Sequence[float]], names: Sequence[str],
                   k: int = 5) -> list[tuple[str, str, float]]:
    """Largest off-diagonal entries of a ROW-normalised matrix
    (true -> predicted, share of the true class)."""
    norm = normalise_rows(matrix)
    pairs = [(names[i], names[j], norm[i][j])
             for i in range(len(norm)) for j in range(len(norm[i]))
             if i != j and norm[i][j] > 0]
    return sorted(pairs, key=lambda p: -p[2])[:k]


# ---------------------------------------------------------------- counting
@dataclass
class CountingResult:
    cls: str
    segments: int
    mae: float                # mean absolute error, bolls per segment
    mape: float | None        # mean absolute % error over segments with true > 0
    total_true: int
    total_pred: int
    bias_pct: float | None    # (sum pred - sum true) / sum true * 100


def counting_errors(rows: Iterable[dict]) -> list[CountingResult]:
    """rows: dicts with keys segment, cls, true, pred (one per segment x class).
    Typically loaded from experiments/E3/counts.csv with load_count_csv()."""
    by_cls: dict[str, list[tuple[int, int]]] = {}
    for r in rows:
        by_cls.setdefault(r["cls"], []).append((int(r["true"]), int(r["pred"])))
    results = []
    for cls, pairs in sorted(by_cls.items()):
        abs_err = [abs(p - t) for t, p in pairs]
        pct = [abs(p - t) / t * 100 for t, p in pairs if t > 0]
        tt, tp = sum(t for t, _ in pairs), sum(p for _, p in pairs)
        results.append(CountingResult(
            cls, len(pairs), round(statistics.mean(abs_err), 3),
            round(statistics.mean(pct), 2) if pct else None, tt, tp,
            round((tp - tt) / tt * 100, 2) if tt else None))
    return results


def load_count_csv(path: str | Path) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    need = {"segment", "cls", "true", "pred"}
    if rows and not need <= set(rows[0]):
        raise ValueError(f"{path}: columns must include {sorted(need)}")
    return rows


# ------------------------------------------------------------------- speed
@dataclass
class SpeedResult:
    frames: int
    fps: float
    latency_p50_ms: float
    latency_p90_ms: float


def speed_from_latencies(latencies_s: Sequence[float], warmup: int = 5) -> SpeedResult:
    """Per-frame end-to-end latencies (seconds). The first `warmup` frames
    are dropped (model loading, caches)."""
    lat = list(latencies_s)[warmup:]
    if len(lat) < 2:
        raise ValueError("need more frames than the warm-up")
    q = statistics.quantiles(lat, n=10)
    return SpeedResult(len(lat), round(len(lat) / sum(lat), 2),
                       round(statistics.median(lat) * 1000, 1), round(q[8] * 1000, 1))
