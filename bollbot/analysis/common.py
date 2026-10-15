"""Shared pieces of the experiment analyses (spec Section 13).

Every analysis returns an `ExperimentResult`: KPIs checked against the PRE-REGISTERED targets in
config/experiments.yaml, tables and figures. A KPI is MET, MISSED, or NOT MEASURED (no data
yet); a missed target stays in the report with its reason (spec rule).
"""
from __future__ import annotations

import csv
import hashlib
import math
import statistics
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence

import yaml

PACKAGE_DIR = Path(__file__).resolve().parent.parent
CONFIG = PACKAGE_DIR / "config" / "experiments.yaml"
EXPERIMENTS_DIR = PACKAGE_DIR / "experiments"


def load_targets(path: Path = CONFIG) -> dict:
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def targets_sha256(path: Path = CONFIG) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DataError(ValueError):
    """The data file is missing, malformed or too small to analyse. Shown, never hidden."""


# ----------------------------------------------------------------------------- results
@dataclass
class Kpi:
    key: str
    label: str
    value: Optional[float]
    op: str                    # ">=", "<=" or "report"
    target: Optional[float]
    note: str = ""

    @property
    def status(self) -> str:
        if self.value is None:
            return "NOT MEASURED"
        if self.op == "report":
            return "REPORTED"
        ok = self.value >= self.target if self.op == ">=" else self.value <= self.target
        return "MET" if ok else "MISSED"

    @property
    def target_text(self) -> str:
        return "reported" if self.op == "report" else f"{self.op} {fmt(self.target)}"


@dataclass
class ExperimentResult:
    exp: str
    title: str
    kpis: list[Kpi] = field(default_factory=list)
    tables: dict[str, list[dict]] = field(default_factory=dict)
    figures: list[Path] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    n: Optional[int] = None        # sample size actually analysed

    def kpi(self, key: str) -> Kpi:
        return next(k for k in self.kpis if k.key == key)

    @property
    def status(self) -> str:
        states = {k.status for k in self.kpis if k.op != "report"}
        if not states or states == {"NOT MEASURED"}:
            return "NO DATA"
        if "MISSED" in states:
            return "MISSED"
        if "NOT MEASURED" in states:
            return "PARTIAL"
        return "MET"


def new_result(exp: str, targets: dict | None = None) -> ExperimentResult:
    """An empty result with every pre-registered KPI 'not measured'."""
    spec = (targets or load_targets())[exp]
    res = ExperimentResult(exp, spec["title"])
    for key, k in spec["kpis"].items():
        res.kpis.append(Kpi(key, k["label"], None, k["op"], k.get("target")))
    return res


def set_kpi(res: ExperimentResult, key: str, value: Optional[float], note: str = "") -> None:
    k = res.kpi(key)
    k.value = None if value is None else float(value)
    if note:
        k.note = note


def check_sample(res: ExperimentResult, n: int, minimum: int, what: str) -> None:
    """Below the planned sample size the result is still computed, but flagged."""
    if n < minimum:
        res.notes.append(f"Only {n} {what} analysed; the protocol plans at least {minimum}. "
                         "Report this as a limitation.")


def fmt(v: Any, digits: int = 2) -> str:
    if v is None:
        return "-"
    if isinstance(v, float):
        if math.isnan(v):
            return "-"
        return f"{v:.{digits}f}".rstrip("0").rstrip(".") if v != int(v) else str(int(v))
    return str(v)


# ----------------------------------------------------------------------------- data files
def read_csv(path: Path, required: Iterable[str]) -> list[dict]:
    """Rows of a CSV with the required columns. Blank lines and lines starting with # are
    skipped, so a template's comment lines never count as data."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(path)
    with open(path, newline="", encoding="utf-8-sig") as fh:
        lines = [ln for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    rows = list(csv.DictReader(lines))
    if not lines:
        return []
    header = next(csv.reader(lines[:1]))
    missing = sorted(set(required) - {h.strip() for h in header})
    if missing:
        raise DataError(f"{path.name}: missing column(s) {missing}; see the template in the same folder")
    return [{k.strip(): (v.strip() if isinstance(v, str) else v) for k, v in r.items() if k} for r in rows]


def num(row: dict, key: str, path: str = "", required: bool = True) -> Optional[float]:
    raw = row.get(key, "")
    if raw in ("", None):
        if required:
            raise DataError(f"{path}: empty '{key}' in row {row}")
        return None
    try:
        return float(raw)
    except ValueError:
        raise DataError(f"{path}: '{key}' is not a number: {raw!r}") from None


def flag(row: dict, key: str, path: str = "") -> bool:
    raw = str(row.get(key, "")).strip().lower()
    if raw in ("1", "true", "yes", "y"):
        return True
    if raw in ("0", "false", "no", "n"):
        return False
    raise DataError(f"{path}: '{key}' must be 1/0 or yes/no, got {raw!r}")


# ----------------------------------------------------------------------------- statistics
def percentile(values: Sequence[float], p: float) -> float:
    """Linear-interpolation percentile (p in 0..100), as numpy's default."""
    xs = sorted(values)
    if not xs:
        raise ValueError("no values")
    k = (len(xs) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def wilson(successes: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95 % Wilson score interval for a proportion, in %. Honest for small samples."""
    if n == 0:
        return (float("nan"), float("nan"))
    p = successes / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (100 * (c - r) / d, 100 * (c + r) / d)


def cohen_kappa(pairs: Sequence[tuple[bool, bool]]) -> Optional[float]:
    """Kappa for two binary raters (predicted, actual). None when undefined (chance = 1)."""
    n = len(pairs)
    if n == 0:
        return None
    po = sum(a == b for a, b in pairs) / n
    pa = sum(a for a, _ in pairs) / n
    pb = sum(b for _, b in pairs) / n
    pe = pa * pb + (1 - pa) * (1 - pb)
    return None if pe == 1 else (po - pe) / (1 - pe)


def confusion(pairs: Sequence[tuple[bool, bool]]) -> dict[str, int]:
    """(predicted, actual) -> counts of true/false positives/negatives."""
    return {
        "tp": sum(p and a for p, a in pairs), "fp": sum(p and not a for p, a in pairs),
        "fn": sum(a and not p for p, a in pairs), "tn": sum(not p and not a for p, a in pairs),
    }


def mean(values: Sequence[float]) -> Optional[float]:
    return statistics.fmean(values) if values else None


# ----------------------------------------------------------------------------- figures
def figure_path(out_dir: Optional[Path], exp: str, name: str) -> Optional[Path]:
    if out_dir is None:
        return None
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir / f"{exp}_{name}.png"


def save(fig, path: Optional[Path], res: ExperimentResult) -> None:
    """Saves a matplotlib figure (if an output folder was given) and records it."""
    import matplotlib.pyplot as plt
    if path is not None:
        fig.tight_layout()
        fig.savefig(path, dpi=150)
        res.figures.append(path)
    plt.close(fig)


def pyplot():
    """matplotlib with a non-interactive backend (works on servers and in CI)."""
    import matplotlib
    matplotlib.use("Agg", force=False)
    import matplotlib.pyplot as plt
    return plt
