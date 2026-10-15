"""E6 pest signals and ETL logic; E7 spot-spray targeting (spec Sections 9, 13).

E6: (a) the rule cases in experiments/E6/rule_cases.yaml, run through the real engine;
    (b) pest_signals.csv: camera signal vs operator scouting on the same segments, for the pest
        classes 5-7 (rosette_flower, boll_bored, mealybug_colony).
E7: cards.csv (one row per dye card) and volume.csv (tank weighed before and after). A card's
    deposit is either typed in (deposit_pct) or measured from its photo (image) with
    card_deposit_pct().
"""
from __future__ import annotations

from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import yaml

from bollbot.core.config import load_etl, load_thresholds
from bollbot.core.engine import run_farm
from bollbot.core.models import ConfirmedDetection, ManualObservation, SegmentScan, TrapCount
from bollbot.core.rules import IST

from .common import (DataError, ExperimentResult, check_sample, figure_path, flag, load_targets, new_result, num,
                     pyplot, read_csv, save, set_kpi, wilson)

PEST_CLASSES = ("rosette_flower", "boll_bored", "mealybug_colony")   # detector classes 5-7
RUN_AT = datetime(2027, 1, 18, 11, 0, tzinfo=IST)                    # fixed: cases do not depend on the clock
FARM = "E6"


# ----------------------------------------------------------------------------- E6 rule cases
def run_case(case: dict, thresholds: dict, pests: dict) -> tuple[bool, str]:
    """Runs one rule case through the engine. Returns (passed, what happened)."""
    today = RUN_AT.date()
    obs = [ManualObservation(FARM, today - timedelta(days=o.get("days_ago", 0)), o["observation"], o["count"], o["units"])
           for o in case.get("observations", [])]
    traps = [TrapCount(FARM, t["trap"], today - timedelta(days=t["days_ago"]), t["moths"]) for t in case.get("traps", [])]
    scans = [SegmentScan(FARM, s["row"], s["segment"], RUN_AT - timedelta(hours=s.get("hours_ago", 1)), dict(s["counts"]), "case")
             for s in case.get("scans", [])]
    conf = [ConfirmedDetection(FARM, c["row"], c["segment"], c["class"], today - timedelta(days=c.get("days_ago", 0)))
            for c in case.get("confirmations", [])]
    report = run_farm(FARM, RUN_AT, thresholds, pests, scans=scans, traps=traps, manual=obs, confirmed=conf)
    rule = case["rule"]
    finding = next((f for f in report.findings if f.pest == rule), None)
    if finding is None:
        return False, f"no rule named {rule!r}"
    got = "insufficient" if finding.insufficient else ("crossed" if finding.crossed else "not_crossed")
    problems = []
    if got != case["expect"]:
        problems.append(f"finding {got}, expected {case['expect']}")
    advice = [a for a in report.advisories if a.pest == rule]
    want = case.get("advisory")
    if want:
        match = [a for a in advice if a.type.value == want["type"]]
        if not match:
            problems.append(f"no {want['type']} advisory (got {[a.type.value for a in advice] or 'none'})")
        elif "segments" in want and sorted(match[0].segments) != sorted(want["segments"]):
            problems.append(f"segments {match[0].segments}, expected {want['segments']}")
    if case.get("no_advisory") and advice:
        problems.append(f"unexpected advisory {[a.type.value for a in advice]}")
    return (not problems), ("; ".join(problems) if problems else f"{got} ({finding.detail})")


def e6(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E6"]
    res = new_result("E6", targets)
    cases_path = data_dir / "rule_cases.yaml"
    if cases_path.exists():
        cases = yaml.safe_load(cases_path.read_text(encoding="utf-8")) or []
        thresholds, pests = load_thresholds(), load_etl()
        table = []
        for case in cases:
            try:
                ok, what = run_case(case, thresholds, pests)
            except (KeyError, TypeError, ValueError) as e:
                ok, what = False, f"case could not run: {e}"
            table.append({"case": case["id"], "rule": case["rule"], "expected": case["expect"], "result": "PASS" if ok else "FAIL",
                          "detail": what, "source": case.get("source", "")})
        res.tables["rule_cases"] = table
        passed = sum(r["result"] == "PASS" for r in table)
        set_kpi(res, "rule_cases", len(table))
        set_kpi(res, "rule_cases_pass_pct", 100 * passed / len(table) if table else None, f"{passed} of {len(table)} passed")
    else:
        res.notes.append("rule_cases.yaml is missing.")
    sig = data_dir / "pest_signals.csv"
    if not sig.exists():
        res.notes.append("No camera-vs-scouting data yet: fill pest_signals.csv (see pest_signals_template.csv).")
        return res
    rows = read_csv(sig, ["segment", "cls", "camera_count", "scout_found"])
    per = []
    tp_all = fp_all = fn_all = 0
    for cls in PEST_CLASSES:
        rs = [r for r in rows if r["cls"] == cls]
        if not rs:
            continue
        pairs = [(num(r, "camera_count", sig.name) > 0, flag(r, "scout_found", sig.name)) for r in rs]
        tp = sum(p and a for p, a in pairs)
        fp = sum(p and not a for p, a in pairs)
        fn = sum(a and not p for p, a in pairs)
        tp_all, fp_all, fn_all = tp_all + tp, fp_all + fp, fn_all + fn
        per.append({"class": cls, "segments": len(rs), "camera+ scout+": tp, "camera+ scout-": fp, "camera- scout+": fn,
                    "precision": round(tp / (tp + fp), 3) if tp + fp else None, "recall": round(tp / (tp + fn), 3) if tp + fn else None})
    unknown = sorted({r["cls"] for r in rows} - set(PEST_CLASSES))
    if unknown:
        raise DataError(f"{sig.name}: classes must be {', '.join(PEST_CLASSES)}; got {unknown}")
    res.tables["camera_vs_scouting"] = per
    set_kpi(res, "camera_precision_5_7", tp_all / (tp_all + fp_all) if tp_all + fp_all else None, "pooled over classes 5-7")
    set_kpi(res, "camera_recall_5_7", tp_all / (tp_all + fn_all) if tp_all + fn_all else None, "pooled over classes 5-7")
    segments = len({r["segment"] for r in rows})
    res.n = segments
    check_sample(res, segments, t["min_segments"], "segments")
    return res


# ----------------------------------------------------------------------------- E7
def card_deposit_pct(image_path: str | Path, hue_range: tuple[int, int] = (95, 135), min_saturation: int = 70) -> float:
    """Share of a dye card covered by dye, in %. The photo must show only the card (crop it).
    Default hue range: blue food dye (OpenCV hue 0-179). Measure the range for your dye once on a
    fully sprayed card and a clean one, and keep it fixed for the whole experiment."""
    import cv2
    import numpy as np
    img = cv2.imread(str(image_path))
    if img is None:
        raise DataError(f"cannot read card image {image_path}")
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    lo = np.array([hue_range[0], min_saturation, 40], dtype=np.uint8)
    hi = np.array([hue_range[1], 255, 255], dtype=np.uint8)
    mask = cv2.inRange(hsv, lo, hi)
    return float(100.0 * np.count_nonzero(mask) / mask.size)


def e7(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E7"]
    res = new_result("E7", targets)
    cards_path = data_dir / "cards.csv"
    if not cards_path.exists():
        res.notes.append("No data yet: fill cards.csv and volume.csv (see the templates).")
        return res
    rows = read_csv(cards_path, ["plant_id", "card"])
    scored = []
    for r in rows:
        kind = r["card"].lower()
        if kind not in ("target", "neighbour"):
            raise DataError(f"{cards_path.name}: card must be 'target' or 'neighbour', got {r['card']!r}")
        dep = num(r, "deposit_pct", cards_path.name, required=False)
        if dep is None:
            image = r.get("image", "")
            if not image:
                raise DataError(f"{cards_path.name}: plant {r['plant_id']} has neither deposit_pct nor image")
            dep = card_deposit_pct(data_dir / image)
        scored.append({"plant_id": r["plant_id"], "card": kind, "deposit %": round(dep, 1), "hit": dep >= t["hit_min_deposit_pct"]})
    target = [s for s in scored if s["card"] == "target"]
    neighbour = [s for s in scored if s["card"] == "neighbour"]
    if target:
        hits = sum(s["hit"] for s in target)
        lo, hi = wilson(hits, len(target))
        set_kpi(res, "target_hit_pct", 100 * hits / len(target), f"{hits} of {len(target)} (95% CI {lo:.0f}-{hi:.0f}%)")
    if neighbour:
        hits = sum(s["hit"] for s in neighbour)
        set_kpi(res, "non_target_hit_pct", 100 * hits / len(neighbour), f"{hits} of {len(neighbour)} neighbour cards")
    res.tables["cards"] = scored
    res.n = len(target)
    check_sample(res, len(target), t["targets"], "target plants")
    vol = data_dir / "volume.csv"
    if vol.exists():
        vrows = read_csv(vol, ["tank_before_g", "tank_after_g"])
        used = sum(num(r, "tank_before_g", vol.name) - num(r, "tank_after_g", vol.name) for r in vrows)
        blanket = t["plants"] * t["blanket_ml_per_plant"]
        set_kpi(res, "volume_vs_blanket_pct", 100 * used / blanket, f"{used:.0f} ml used (water: 1 g = 1 ml) vs blanket {blanket:.0f} ml")
    else:
        res.notes.append("volume.csv missing: spray volume not measured.")
    if scored:
        plt = pyplot()
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.hist([[s["deposit %"] for s in target], [s["deposit %"] for s in neighbour]], bins=20, label=["target", "neighbour"])
        ax.axvline(t["hit_min_deposit_pct"], ls="--", c="grey", lw=1, label="hit threshold")
        ax.set_xlabel("card area covered by dye (%)")
        ax.set_ylabel("cards")
        ax.set_title("E7 - dye deposit on target and neighbour cards")
        ax.legend()
        save(fig, figure_path(out_dir, "E7", "deposits"), res)
    return res
