"""E4 picking-window rule vs oven-dry moisture; E5 depth and localisation (spec Sections 7, 8).

E4 reads moisture.csv: one row per pooled sample, in COLLECTION ORDER, with the four rule inputs
recorded at sampling time and the two weighings. The rule is the cart's own
core.rules.picking_window. Thresholds are tuned on the first `tune_samples` rows only; the
success criterion is agreement on the remaining rows (pre-registered, spec Section 8).

E5 reads pegboard.csv (true vs estimated 3D points, optional arm miss) and segments.csv (true vs
logged segment ID per row).
"""
from __future__ import annotations

import copy
import itertools
import math
from datetime import datetime
from pathlib import Path
from typing import Optional

from bollbot.core.config import load_thresholds
from bollbot.core.models import WeatherReading, WindowStatus
from bollbot.core.rules import IST, picking_window, wet_basis_moisture

from .common import (DataError, ExperimentResult, check_sample, cohen_kappa, confusion, figure_path, load_targets,
                     new_result, num, percentile, pyplot, read_csv, save, set_kpi, wilson)

E4_COLUMNS = ["sample_id", "date", "time", "segment", "t_c", "rh", "rain_24h_mm", "w_wet_g", "w_dry_g"]


def _sample_time(row: dict, path: str) -> datetime:
    try:
        return datetime.fromisoformat(f"{row['date']}T{row['time']}").replace(tzinfo=IST)
    except ValueError:
        raise DataError(f"{path}: bad date/time {row['date']!r} {row['time']!r} (use 2026-11-03 and 10:30)") from None


def _rule_safe(row: dict, cfg: dict) -> bool:
    w = WeatherReading(row["t_c"], row["rh"])
    return picking_window(w, row["when"], row["rain"], cfg).status is WindowStatus.SAFE


def _with(cfg: dict, values: dict) -> dict:
    out = copy.deepcopy(cfg)
    out["picking_window"].update(values)
    return out


def _score(rows: list[dict], cfg: dict) -> tuple[float, Optional[float], dict]:
    pairs = [(_rule_safe(r, cfg), r["oven_safe"]) for r in rows]
    agree = 100 * sum(p == a for p, a in pairs) / len(pairs)
    return agree, cohen_kappa(pairs), confusion(pairs)


def e4(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None, thresholds: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E4"]
    res = new_result("E4", targets)
    path = data_dir / "moisture.csv"
    if not path.exists():
        res.notes.append("No data yet: fill moisture.csv in collection order (see moisture_template.csv).")
        return res
    raw = read_csv(path, E4_COLUMNS)
    rows = []
    for r in raw:
        wet, dry = num(r, "w_wet_g", path.name), num(r, "w_dry_g", path.name)
        try:
            moisture = wet_basis_moisture(wet, dry)
        except ValueError as e:
            raise DataError(f"{path.name}, sample {r['sample_id']}: {e}") from None
        rows.append({
            "id": r["sample_id"], "when": _sample_time(r, path.name), "t_c": num(r, "t_c", path.name),
            "rh": num(r, "rh", path.name), "rain": num(r, "rain_24h_mm", path.name), "moisture": moisture,
            "oven_safe": moisture <= t["safe_moisture_max_pct"],
        })
    res.n = len(rows)
    check_sample(res, len(rows), t["min_samples"], "samples")
    k = t["tune_samples"]
    if len(rows) <= k:
        res.notes.append(f"{len(rows)} samples: the test half starts after sample {k}. Agreement is not measured yet.")
        return res
    tune, test = rows[:k], rows[k:]
    cfg = thresholds or load_thresholds()

    init_agree, init_kappa, init_conf = _score(test, cfg)
    grid = t["grid"]
    keys = list(grid)
    best = None
    for combo in itertools.product(*(grid[key] for key in keys)):
        values = dict(zip(keys, combo))
        agree, kappa, _ = _score(tune, _with(cfg, values))
        # Highest tune agreement; ties -> higher kappa, then the values closest to the initial rule.
        distance = sum(abs(values[key] - cfg["picking_window"][key]) for key in keys)
        rank = (agree, -1 if kappa is None else kappa, -distance)
        if best is None or rank > best[0]:
            best = (rank, values)
    tuned = best[1]
    tuned_agree, tuned_kappa, tuned_conf = _score(test, _with(cfg, tuned))

    set_kpi(res, "test_agreement_pct", tuned_agree, "rule tuned on the first half, scored on the second")
    set_kpi(res, "test_kappa", tuned_kappa)
    n_test = len(test)
    lo, hi = wilson(round(tuned_agree * n_test / 100), n_test)
    res.tables["rules"] = [
        {"rule": "initial (thresholds.yaml)", **cfg["picking_window"], "test agreement %": round(init_agree, 1),
         "kappa": None if init_kappa is None else round(init_kappa, 3), **init_conf},
        {"rule": "tuned on first half", **{**cfg["picking_window"], **tuned}, "test agreement %": round(tuned_agree, 1),
         "kappa": None if tuned_kappa is None else round(tuned_kappa, 3), **tuned_conf},
    ]
    res.notes.append(f"Test half: {n_test} samples; agreement 95% CI {lo:.0f}-{hi:.0f}% (Wilson).")
    res.notes.append("Confusion columns: tp = rule SAFE and oven <= 8 %; fp = rule SAFE but oven > 8 % (the costly error).")
    if tuned_agree < t["kpis"]["test_agreement_pct"]["target"]:
        res.notes.append("Target missed: report the best rule and its agreement; do not claim moisture sensing (spec Section 8).")

    plt = pyplot()
    fig, ax = plt.subplots(figsize=(6, 4))
    for safe, colour, label in ((True, "tab:green", "oven <= 8 %"), (False, "tab:red", "oven > 8 %")):
        pts = [r for r in rows if r["oven_safe"] == safe]
        dep = []
        for r in pts:
            w = WeatherReading(r["t_c"], r["rh"])
            dep.append(picking_window(w, r["when"], r["rain"], cfg).dewpoint_depression_c)
        ax.scatter(dep, [r["moisture"] for r in pts], c=colour, label=label, alpha=0.7)
    ax.axhline(t["safe_moisture_max_pct"], ls="--", c="grey", lw=1)
    ax.axvline(cfg["picking_window"]["min_dewpoint_depression_c"], ls=":", c="grey", lw=1, label="initial T - Td limit")
    ax.set_xlabel("dew-point depression T - Td at sampling (C)")
    ax.set_ylabel("seed-cotton moisture, wet basis (%)")
    ax.set_title("E4 - moisture vs dew-point depression")
    ax.legend()
    save(fig, figure_path(out_dir, "E4", "moisture"), res)
    return res


# ----------------------------------------------------------------------------- E5
def e5(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E5"]
    res = new_result("E5", targets)
    peg = data_dir / "pegboard.csv"
    seg = data_dir / "segments.csv"
    if not peg.exists() and not seg.exists():
        res.notes.append("No data yet: fill pegboard.csv and segments.csv (see the templates).")
        return res
    if peg.exists():
        rows = read_csv(peg, ["point", "true_x_m", "true_y_m", "true_z_m", "est_x_m", "est_y_m", "est_z_m"])
        errors = []
        table = []
        for r in rows:
            e = 100 * math.dist([num(r, f"true_{a}_m", peg.name) for a in "xyz"], [num(r, f"est_{a}_m", peg.name) for a in "xyz"])
            miss = num(r, "arm_miss_cm", peg.name, required=False)
            errors.append(e)
            table.append({"point": r["point"], "distance_m": round(num(r, "true_z_m", peg.name), 2), "camera error cm": round(e, 2), "arm miss cm": miss})
        res.tables["points"] = table
        res.n = len(rows)
        check_sample(res, len(rows), t["min_points"], "pegboard points")
        set_kpi(res, "mean_error_cm", sum(errors) / len(errors))
        set_kpi(res, "p95_error_cm", percentile(errors, 95))
        set_kpi(res, "max_error_cm", max(errors))
        misses = [r["arm miss cm"] for r in table if r["arm miss cm"] is not None]
        if misses:
            set_kpi(res, "arm_within_3cm_pct", 100 * sum(m <= 3.0 for m in misses) / len(misses), f"{len(misses)} arm touches")
        plt = pyplot()
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.scatter([r["distance_m"] for r in table], [r["camera error cm"] for r in table])
        ax.axhline(t["kpis"]["mean_error_cm"]["target"], ls="--", c="grey", lw=1, label="mean-error target")
        ax.set_xlabel("distance from camera (m)")
        ax.set_ylabel("3D error (cm)")
        ax.set_title("E5 - stereo position error by distance")
        ax.legend()
        save(fig, figure_path(out_dir, "E5", "error_by_distance"), res)
    if seg.exists():
        rows = read_csv(seg, ["row", "true_segment", "logged_segment"])
        ok = sum(r["true_segment"].upper() == r["logged_segment"].upper() for r in rows)
        set_kpi(res, "segment_id_accuracy_pct", 100 * ok / len(rows) if rows else None, f"{ok} of {len(rows)} passes")
        wrong = [r for r in rows if r["true_segment"].upper() != r["logged_segment"].upper()]
        if wrong:
            res.tables["segment_errors"] = wrong
        rows_seen = len({r["row"] for r in rows})
        check_sample(res, rows_seen, t["min_rows"], "rows in the segment-ID check")
    return res
