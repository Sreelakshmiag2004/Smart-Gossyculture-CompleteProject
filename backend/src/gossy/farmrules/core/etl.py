"""Economic-threshold (ETL) evaluation for cotton pests (spec Section 9).

Each rule in config/etl.yaml is evaluated against the evidence the caller
supplies (already filtered to one farm and a recent time window). Rules
never fire on too little evidence: they return `insufficient=True`
instead, and the app shows 'scout more' rather than a false alarm.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Iterable, Optional

from .models import ConfirmedDetection, ManualObservation, SegmentScan, TrapCount
from .rules import latest_by_segment


@dataclass
class EtlInputs:
    scans: list[SegmentScan] = field(default_factory=list)
    traps: list[TrapCount] = field(default_factory=list)
    manual: list[ManualObservation] = field(default_factory=list)
    confirmed: list[ConfirmedDetection] = field(default_factory=list)


@dataclass
class PestFinding:
    pest: str
    crossed: bool
    value: Optional[float]
    threshold: float
    action: str
    insufficient: bool = False
    detail: str = ""
    segments: list[str] = field(default_factory=list)


# ------------------------------------------------------------------ helpers
def _op(rule: dict) -> str:
    return ">" if rule.get("strict") else ">="


def crossed(value: float, rule: dict) -> bool:
    """Compare with the rule's threshold. `strict: true` means 'more than'
    (the wording of the 2014 AESA package); otherwise 'at or above'."""
    t = rule["threshold"]
    return value > t if rule.get("strict") else value >= t


def _latest_date_obs(obs: Iterable[ManualObservation], key: str) -> list[ManualObservation]:
    matching = [o for o in obs if o.observation == key]
    if not matching:
        return []
    last = max(o.date for o in matching)
    return [o for o in matching if o.date == last]


def nightly_trap_means(traps: Iterable[TrapCount], prefix: str) -> dict[date, float]:
    """Mean moths per trap for each night, for traps whose id starts with prefix."""
    per_night: dict[date, list[int]] = defaultdict(list)
    for t in traps:
        if t.trap.upper().startswith(prefix.upper()):
            per_night[t.date].append(t.moths)
    return {d: sum(v) / len(v) for d, v in per_night.items()}


def longest_run_at_or_above(means: dict[date, float], threshold: float,
                            strict: bool = False) -> int:
    """Longest run of consecutive calendar nights with mean >= threshold
    (or > threshold when strict)."""
    hit = (lambda v: v > threshold) if strict else (lambda v: v >= threshold)
    best = run = 0
    prev: Optional[date] = None
    for d in sorted(means):
        if hit(means[d]):
            run = run + 1 if prev is not None and d - prev == timedelta(days=1) \
                and hit(means[prev]) else 1
            best = max(best, run)
        else:
            run = 0
        prev = d
    return best


# --------------------------------------------------------------- evaluators
def _consecutive_nights(key: str, rule: dict, inp: EtlInputs) -> PestFinding:
    means = nightly_trap_means(inp.traps, rule.get("trap_prefix", ""))
    need = int(rule["nights"])
    if len(means) < need:
        return PestFinding(key, False, None, rule["threshold"], rule["action"],
                           insufficient=True,
                           detail=f"{len(means)} nights of trap data, need {need}")
    run = longest_run_at_or_above(means, rule["threshold"], bool(rule.get("strict")))
    return PestFinding(key, run >= need, float(run), rule["threshold"], rule["action"],
                       detail=f"{run} consecutive nights {_op(rule)} {rule['threshold']} moths/trap")


def _camera_ratio(key: str, rule: dict, inp: EtlInputs) -> PestFinding:
    num = den = 0
    segs = []
    # Only the latest scan of each segment counts: re-scanning the same plants
    # must not add them to the sample again (QA bug 3).
    for s in latest_by_segment(inp.scans).values():
        n = sum(s.counts.get(c, 0) for c in rule["numerator"])
        num += n
        den += sum(s.counts.get(c, 0) for c in rule["denominator"])
        if n:
            segs.append(s.segment_key)
    min_den = rule.get("min_denominator", 1)
    if den < min_den:
        return PestFinding(key, False, None, rule["threshold"], rule["action"],
                           insufficient=True,
                           detail=f"{den} fruiting bodies seen, need {min_den}")
    ratio = num / den
    return PestFinding(key, crossed(ratio, rule), round(ratio, 4),
                       rule["threshold"], rule["action"],
                       detail=f"{num}/{den} damaged", segments=sorted(set(segs)))


def _per_unit(key: str, rule: dict, inp: EtlInputs, percent: bool) -> PestFinding:
    obs = _latest_date_obs(inp.manual, rule["observation"])
    units = sum(o.units for o in obs)
    count = sum(o.count for o in obs)
    min_units = rule.get("min_units", 1)
    if units < min_units:
        return PestFinding(key, False, None, rule["threshold"], rule["action"],
                           insufficient=True,
                           detail=f"{units} units observed, need {min_units}")
    value = count / units * (100 if percent else 1)
    return PestFinding(key, crossed(value, rule), round(value, 3),
                       rule["threshold"], rule["action"],
                       detail=f"{count} over {units} units on {obs[0].date}")


def _presence(key: str, rule: dict, inp: EtlInputs) -> PestFinding:
    if rule.get("source") == "camera_confirmed":
        hits = [c for c in inp.confirmed if c.cls == rule["class"]]
        segs = sorted({f"R{c.row:03d}-S{c.segment:02d}" for c in hits})
        n = len(hits)
        return PestFinding(key, crossed(n, rule), float(n), rule["threshold"],
                           rule["action"], detail=f"{n} confirmed", segments=segs)
    obs = _latest_date_obs(inp.manual, rule["observation"])
    n = sum(o.count for o in obs)
    return PestFinding(key, crossed(n, rule), float(n), rule["threshold"],
                       rule["action"], detail=f"{n} reported")


_EVALUATORS = {
    "consecutive_nights": _consecutive_nights,
    "camera_ratio": _camera_ratio,
    "mean_per_unit": lambda k, r, i: _per_unit(k, r, i, percent=False),
    "percent_units": lambda k, r, i: _per_unit(k, r, i, percent=True),
    "presence": _presence,
}


def evaluate(pests: dict[str, dict], inputs: EtlInputs) -> list[PestFinding]:
    """Evaluate every pest rule. Order follows etl.yaml.

    A rule with `locate_class` takes its segments from human-confirmed
    detections of that class: the threshold decides WHETHER to act, the
    confirmed detections say WHERE.
    """
    findings = []
    for key, rule in pests.items():
        f = _EVALUATORS[rule["type"]](key, rule, inputs)
        loc = rule.get("locate_class")
        if loc:
            f.segments = sorted({f"R{c.row:03d}-S{c.segment:02d}"
                                 for c in inputs.confirmed if c.cls == loc})
        findings.append(f)
    return findings
