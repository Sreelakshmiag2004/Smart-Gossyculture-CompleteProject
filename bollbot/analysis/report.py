"""Runs every experiment analysis and writes the results the Phase II report quotes.

    python -m bollbot.analysis.report                 # all experiments with data
    python -m bollbot.analysis.report --only E4 E6    # some of them

Outputs (in bollbot/experiments/): results.md (KPI table + details), results.json, figures/*.png.
Experiments without data are listed as NO DATA; a missed target is listed as MISSED, with its
value. Nothing is left out (spec Section 13).
"""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from typing import Callable

from bollbot.core.rules import IST

from .common import CONFIG, EXPERIMENTS_DIR, DataError, ExperimentResult, fmt, load_targets, new_result, targets_sha256
from .e1_e2_e3 import e1, e2, e3
from .e4_e5 import e4, e5
from .e6_e7 import e6, e7
from .e8_to_e11 import e8, e9, e10, e11

ANALYSES: dict[str, Callable[..., ExperimentResult]] = {
    "E1": e1, "E2": e2, "E3": e3, "E4": e4, "E5": e5, "E6": e6, "E7": e7, "E8": e8, "E9": e9, "E10": e10, "E11": e11,
}


def run_all(experiments_dir: Path = EXPERIMENTS_DIR, only: list[str] | None = None, figures: bool = True) -> list[ExperimentResult]:
    targets = load_targets()
    out = []
    fig_dir = experiments_dir / "figures" if figures else None
    for exp, fn in ANALYSES.items():
        if only and exp not in only:
            continue
        try:
            out.append(fn(experiments_dir / exp, fig_dir, targets))
        except (DataError, FileNotFoundError) as e:
            res = new_result(exp, targets)
            res.notes.append(f"DATA PROBLEM: {e}")
            out.append(res)
        except Exception as e:  # noqa: BLE001 - one broken analysis must not hide the others
            res = new_result(exp, targets)
            res.notes.append(f"ANALYSIS ERROR: {type(e).__name__}: {e}")
            res.notes.append(traceback.format_exc(limit=3))
            out.append(res)
    return out


def _table(rows: list[dict]) -> str:
    if not rows:
        return ""
    cols = list(rows[0])
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        lines.append("| " + " | ".join(fmt(r.get(c), 3) for c in cols) + " |")
    return "\n".join(lines)


def to_markdown(results: list[ExperimentResult], experiments_dir: Path) -> str:
    now = datetime.now(IST).strftime("%Y-%m-%d %H:%M IST")
    out = [
        "# BollBot Phase II - experiment results",
        "",
        f"Generated {now} by `python -m bollbot.analysis.report`. Do not edit by hand: re-run it.",
        f"Targets: `config/experiments.yaml`, SHA-256 `{targets_sha256(CONFIG)[:16]}`. The targets were registered before any data",
        "was collected; a changed fingerprint means they were changed afterwards.",
        "",
        "## KPI summary",
        "",
        "| Experiment | KPI | Value | Target | Status | Note |",
        "|---|---|---|---|---|---|",
    ]
    for r in results:
        for k in r.kpis:
            out.append(f"| {r.exp} | {k.label} | {fmt(k.value, 3)} | {k.target_text} | {k.status} | {k.note} |")
    out += ["", "Status: MET / MISSED against the pre-registered target; REPORTED = no pass/fail; NOT MEASURED = no data yet.", ""]
    for r in results:
        out += [f"## {r.exp} - {r.title}", "", f"Overall: **{r.status}**" + (f" (n = {r.n})" if r.n is not None else ""), ""]
        for note in r.notes:
            out.append(f"- {note}")
        if r.notes:
            out.append("")
        for name, rows in r.tables.items():
            if rows:
                out += [f"**{name.replace('_', ' ')}**", "", _table(rows), ""]
        for fig in r.figures:
            out += [f"![{fig.stem}]({fig.relative_to(experiments_dir).as_posix()})", ""]
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Analyse experiments E1-E11 and write results.md")
    p.add_argument("--dir", default=str(EXPERIMENTS_DIR), help="experiments folder (default: bollbot/experiments)")
    p.add_argument("--only", nargs="*", help="e.g. E4 E6")
    p.add_argument("--no-figures", action="store_true")
    a = p.parse_args(argv)
    d = Path(a.dir)
    results = run_all(d, a.only, figures=not a.no_figures)
    (d / "results.md").write_text(to_markdown(results, d), encoding="utf-8")
    (d / "results.json").write_text(json.dumps(
        [{"exp": r.exp, "title": r.title, "status": r.status, "n": r.n, "notes": r.notes,
          "kpis": [{**asdict(k), "status": k.status} for k in r.kpis], "tables": r.tables,
          "figures": [f.relative_to(d).as_posix() for f in r.figures]} for r in results],
        indent=2, default=str), encoding="utf-8")
    width = max(len(r.title) for r in results) if results else 0
    for r in results:
        print(f"{r.exp:4s} {r.title:{width}s}  {r.status}")
    print(f"-> {d / 'results.md'}")
    problems = [r for r in results if any(n.startswith(("DATA PROBLEM", "ANALYSIS ERROR")) for n in r.notes)]
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
