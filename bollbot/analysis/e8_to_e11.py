"""E8 IoT reliability, E9 farmer usability, E10 arm demonstrator, E11 power (spec Section 13).

E8: the cart's outbox database (copy data/outbox.sqlite to experiments/E8/outbox.sqlite) is
    reconciled by message ID against the backend's ingestion ledger (backend_messages.csv,
    exported with the command in experiments/E8/README.md); session.yaml gives the offline window.
E9: sus.csv - one row per farmer: the 10 SUS answers (1-5) and the three tasks (1 done, 0 not).
E10: picks.csv - the arm's attempt log (edge/arm/picker.py) plus the operator's columns
     setting, effector, picked_g.
E11: power*.csv from bollbot.edge.power_log and session.yaml (battery capacity).
"""
from __future__ import annotations

import sqlite3
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

from .common import (DataError, ExperimentResult, check_sample, figure_path, flag, load_targets, new_result, num,
                     percentile, pyplot, read_csv, save, set_kpi, wilson)


def _time(raw: str, where: str) -> datetime:
    try:
        t = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    except ValueError:
        raise DataError(f"{where}: not a timestamp: {raw!r}") from None
    if t.tzinfo is None:
        raise DataError(f"{where}: timestamp without a time zone: {raw!r} (add +05:30 or Z)")
    return t


def _session(data_dir: Path) -> dict:
    path = data_dir / "session.yaml"
    if not path.exists():
        return {}
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


# ----------------------------------------------------------------------------- E8
def e8(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E8"]
    res = new_result("E8", targets)
    db, ledger = data_dir / "outbox.sqlite", data_dir / "backend_messages.csv"
    if not db.exists() or not ledger.exists():
        res.notes.append("No data yet: copy the cart's data/outbox.sqlite and export backend_messages.csv (see README.md).")
        return res
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        cart = con.execute("SELECT msg_id, kind, created, sent FROM outbox WHERE msg_id IS NOT NULL").fetchall()
    finally:
        con.close()
    # Heartbeats are replaced in the outbox by design (only the latest matters), so earlier ones
    # cannot be reconciled from it; every other record keeps its own msgId.
    cart = [r for r in cart if r[1] != "heartbeat"]
    backend_rows = read_csv(ledger, ["msg_id", "received_at"])
    received: dict[str, datetime] = {}
    duplicates = 0
    for r in backend_rows:
        if r["msg_id"] in received:
            duplicates += 1
        received[r["msg_id"]] = _time(r["received_at"], ledger.name)
    session = _session(data_dir)
    off = (session.get("offline_start"), session.get("offline_end"))
    window = None
    if all(off):
        window = (_time(str(off[0]), "session.yaml"), _time(str(off[1]), "session.yaml"))
    else:
        res.notes.append("session.yaml has no offline_start/offline_end: latency is computed over all messages.")

    lost = [m for m, kind, created, sent in cart if m not in received]
    dead = [m for m, kind, created, sent in cart if sent is not None and sent < 0]
    pending = [m for m, kind, created, sent in cart if sent is None]
    online_latency, offline_latency = [], []
    for m, kind, created, sent in cart:
        if m not in received:
            continue
        made = datetime.fromtimestamp(created, timezone.utc)
        delay = (received[m] - made).total_seconds()
        if window and window[0] <= made <= window[1]:
            offline_latency.append(delay)
        else:
            online_latency.append(delay)
    res.n = len(cart)
    check_sample(res, len(cart), t["min_messages"], "messages")
    set_kpi(res, "lost_messages", len(lost), f"{len(cart)} cart messages; {len(pending)} still pending, {len(dead)} dead-lettered")
    set_kpi(res, "duplicates_stored", duplicates)
    if online_latency:
        set_kpi(res, "median_latency_online_s", statistics.median(online_latency), f"{len(online_latency)} messages created while online")
    res.tables["summary"] = [{
        "cart messages": len(cart), "received by backend": len(cart) - len(lost), "lost": len(lost),
        "created while offline": len(offline_latency),
        "offline backlog delivered within (s)": round(max(offline_latency), 1) if offline_latency else None,
        "online latency p90 (s)": round(percentile(online_latency, 90), 2) if online_latency else None,
    }]
    if lost:
        res.tables["lost"] = [{"msg_id": m} for m in lost[:50]]
    if online_latency or offline_latency:
        plt = pyplot()
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.hist([online_latency, offline_latency], bins=30, label=["created online", "created offline"])
        ax.set_xlabel("delay from creation on the cart to receipt by the backend (s)")
        ax.set_ylabel("messages")
        ax.set_yscale("log")
        ax.set_title("E8 - delivery delay")
        ax.legend()
        save(fig, figure_path(out_dir, "E8", "latency"), res)
    return res


# ----------------------------------------------------------------------------- E9
TASKS = ("task_pick_list", "task_tamil_alert", "task_trap_count")


def sus_score(answers: list[int]) -> float:
    """System Usability Scale: odd items (positive) score a-1, even items 5-a; sum x 2.5 (0-100)."""
    if len(answers) != 10 or any(a < 1 or a > 5 for a in answers):
        raise DataError(f"SUS needs 10 answers from 1 to 5, got {answers}")
    return 2.5 * sum((a - 1) if i % 2 == 0 else (5 - a) for i, a in enumerate(answers))


def e9(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E9"]
    res = new_result("E9", targets)
    path = data_dir / "sus.csv"
    if not path.exists():
        res.notes.append("No data yet: fill sus.csv (see sus_template.csv).")
        return res
    rows = read_csv(path, ["participant", "village", *[f"q{i}" for i in range(1, 11)], *TASKS])
    people = []
    for r in rows:
        answers = [int(num(r, f"q{i}", path.name)) for i in range(1, 11)]
        tasks = [flag(r, task, path.name) for task in TASKS]
        people.append({"participant": r["participant"], "village": r["village"], "SUS": sus_score(answers), **dict(zip(TASKS, tasks))})
    res.tables["participants"] = people
    res.n = len(people)
    check_sample(res, len(people), t["min_participants"], "farmers")
    villages = {p["village"] for p in people}
    if len(villages) < t["min_villages"]:
        res.notes.append(f"Only {len(villages)} village(s); the protocol plans at least {t['min_villages']}.")
    scores = [p["SUS"] for p in people]
    sd = statistics.stdev(scores) if len(scores) > 1 else 0.0
    set_kpi(res, "sus_mean", statistics.fmean(scores), f"SD {sd:.1f}, range {min(scores):.0f}-{max(scores):.0f}")
    done = sum(p[t2] for p in people for t2 in TASKS)
    total = len(people) * len(TASKS)
    lo, hi = wilson(done, total)
    set_kpi(res, "task_completion_pct", 100 * done / total, f"{done} of {total} tasks (95% CI {lo:.0f}-{hi:.0f}%)")
    res.tables["tasks"] = [{"task": t2, "completed": sum(p[t2] for p in people), "of": len(people)} for t2 in TASKS]
    plt = pyplot()
    fig, ax = plt.subplots(figsize=(6, 3.5))
    ax.hist(scores, bins=range(0, 105, 5))
    ax.axvline(t["kpis"]["sus_mean"]["target"], ls="--", c="grey", lw=1, label="target 68 (average usability)")
    ax.set_xlabel("SUS score")
    ax.set_ylabel("farmers")
    ax.set_title("E9 - SUS scores (Tamil questionnaire)")
    ax.legend()
    save(fig, figure_path(out_dir, "E9", "sus"), res)
    return res


# ----------------------------------------------------------------------------- E10
def e10(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E10"]
    res = new_result("E10", targets)
    path = data_dir / "picks.csv"
    if not path.exists():
        res.notes.append("No data yet: the arm writes picks.csv during `harvest run`; add setting, effector and picked_g.")
        return res
    rows = read_csv(path, ["id", "result", "cycle_s", "outcome"])
    attempts = []
    for r in rows:
        picked = num(r, "picked_g", path.name, required=False)
        left = num(r, "lint_left_g", path.name, required=False)
        trash = num(r, "trash_g", path.name, required=False)
        if picked is not None and left is not None and picked + left > 0:
            removed = 100 * picked / (picked + left)
            success = removed >= t["success_removed_min_pct"]
        else:
            removed = None
            success = r["outcome"].lower() == "picked"
        attempts.append({
            "id": r["id"], "setting": (r.get("setting") or "bench").lower(), "effector": (r.get("effector") or "vacuum").lower(),
            "result": r["result"], "outcome": r["outcome"], "reason": r.get("reason", ""), "cycle_s": num(r, "cycle_s", path.name),
            "picked_g": picked, "left_g": left, "trash_g": trash, "removed_pct": removed, "success": success,
        })
    main = [a for a in attempts if a["effector"] == "vacuum"]
    res.n = len(main)
    check_sample(res, len(main), t["min_picks"], "vacuum-roller picks")
    if main:
        ok = sum(a["success"] for a in main)
        lo, hi = wilson(ok, len(main))
        set_kpi(res, "success_pct", 100 * ok / len(main), f"{ok} of {len(main)} (95% CI {lo:.0f}-{hi:.0f}%)")
        cycles = [a["cycle_s"] for a in main if a["result"] == "completed" and a["cycle_s"] > 0]
        if cycles:
            set_kpi(res, "cycle_median_s", statistics.median(cycles), f"product need {t['product_cycle_s']} s")
            set_kpi(res, "cycle_p90_s", percentile(cycles, 90))
        weighed = [a for a in main if a["picked_g"] is not None and a["trash_g"] is not None]
        if weighed:
            lint = sum(a["picked_g"] for a in weighed)
            trash = sum(a["trash_g"] for a in weighed)
            set_kpi(res, "trash_pct", 100 * trash / (lint + trash) if lint + trash else None, f"{len(weighed)} weighed picks")
        left = [a for a in main if a["picked_g"] is not None and a["left_g"] is not None]
        if left:
            p, l2 = sum(a["picked_g"] for a in left), sum(a["left_g"] for a in left)
            set_kpi(res, "lint_left_pct", 100 * l2 / (p + l2) if p + l2 else None)
    groups = []
    for setting in sorted({a["setting"] for a in attempts}):
        for eff in sorted({a["effector"] for a in attempts}):
            g = [a for a in attempts if a["setting"] == setting and a["effector"] == eff]
            if g:
                cyc = [a["cycle_s"] for a in g if a["result"] == "completed" and a["cycle_s"] > 0]
                groups.append({"setting": setting, "effector": eff, "attempts": len(g), "success %": round(100 * sum(a["success"] for a in g) / len(g), 1),
                               "median cycle s": round(statistics.median(cyc), 1) if cyc else None})
    res.tables["by_setting_and_effector"] = groups
    reasons: dict[str, int] = {}
    for a in attempts:
        if not a["success"]:
            key = a["reason"] or a["outcome"] or a["result"] or "unknown"
            reasons[key] = reasons.get(key, 0) + 1
    res.tables["failure_reasons"] = [{"reason": k, "count": v} for k, v in sorted(reasons.items(), key=lambda kv: -kv[1])]
    cyc_all = [a["cycle_s"] for a in main if a["result"] == "completed" and a["cycle_s"] > 0]
    if cyc_all:
        plt = pyplot()
        fig, ax = plt.subplots(figsize=(6, 3.5))
        ax.hist(cyc_all, bins=15)
        ax.axvline(t["product_cycle_s"], ls="--", c="tab:red", lw=1, label=f"product need {t['product_cycle_s']} s")
        ax.set_xlabel("cycle time, detected -> home (s)")
        ax.set_ylabel("picks")
        ax.set_title("E10 - vacuum-roller cycle time")
        ax.legend()
        save(fig, figure_path(out_dir, "E10", "cycle_time"), res)
    return res


# ----------------------------------------------------------------------------- E11
def e11(data_dir: Path, out_dir: Optional[Path] = None, targets: dict | None = None) -> ExperimentResult:
    t = (targets or load_targets())["E11"]
    res = new_result("E11", targets)
    files = sorted(data_dir.glob("power*.csv"))
    if not files:
        res.notes.append("No data yet: log with `python -m bollbot.edge.power_log --out experiments/E11/power_day1.csv`.")
        return res
    session = _session(data_dir)
    days = []
    for f in files:
        rows = read_csv(f, ["ts", "voltage_v", "current_a"])
        if len(rows) < 2:
            raise DataError(f"{f.name}: needs at least two readings")
        pts = [(_time(r["ts"], f.name), num(r, "voltage_v", f.name) * num(r, "current_a", f.name)) for r in rows]
        wh = sum((b[0] - a[0]).total_seconds() / 3600 * (a[1] + b[1]) / 2 for a, b in zip(pts, pts[1:]))
        hours = (pts[-1][0] - pts[0][0]).total_seconds() / 3600
        days.append({"log": f.name, "hours logged": round(hours, 2), "energy Wh": round(wh, 1), "mean W": round(wh / hours, 2) if hours else None,
                     "min V": round(min(num(r, "voltage_v", f.name) for r in rows), 2)})
    res.tables["logs"] = days
    res.n = len(days)
    check_sample(res, len(days), t["min_days"], "logged days")
    total_wh = sum(d["energy Wh"] for d in days)
    total_h = sum(d["hours logged"] for d in days)
    mean_w = total_wh / total_h if total_h else None
    set_kpi(res, "mean_power_w", mean_w)
    if session.get("ran_to_cutoff"):
        set_kpi(res, "runtime_h", min(d["hours logged"] for d in days), "measured: each log ran from full charge to the low-voltage cut-off")
    elif session.get("battery_wh") and mean_w:
        usable = float(session["battery_wh"]) * float(session.get("usable_fraction", 0.8))
        set_kpi(res, "runtime_h", usable / mean_w, f"estimated: {usable:.0f} usable Wh / {mean_w:.1f} W (not a full discharge)")
    else:
        res.notes.append("session.yaml needs battery_wh (and usable_fraction), or ran_to_cutoff: true, to report the runtime.")
    return res
