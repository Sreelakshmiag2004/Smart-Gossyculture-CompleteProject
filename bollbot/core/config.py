"""Load YAML configuration. Thresholds live in config/, never in code."""
from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

CONFIG_DIR = Path(__file__).resolve().parent.parent / "config"


def _load(name: str, path: str | Path | None) -> dict[str, Any]:
    p = Path(path) if path else CONFIG_DIR / name
    with open(p, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{p} is empty or not a mapping")
    return data


def load_thresholds(path: str | Path | None = None) -> dict[str, Any]:
    cfg = _load("thresholds.yaml", path)
    for section in ("readiness", "picking_window", "rain_alert", "spray_block"):
        if section not in cfg:
            raise ValueError(f"thresholds.yaml missing section '{section}'")
    r = cfg["readiness"]
    if not 0 <= r["building_min"] <= r["ready_min"] <= 1:
        raise ValueError("need 0 <= building_min <= ready_min <= 1")
    return cfg


def load_ml(path: str | Path | None = None) -> dict[str, Any]:
    cfg = _load("ml.yaml", path)
    for section in ("train", "targets", "rare_class", "export"):
        if section not in cfg:
            raise ValueError(f"ml.yaml missing section '{section}'")
    return cfg


_COMMON_KEYS = {"name_en", "name_ta", "type", "threshold", "action", "strict",
                "source", "locate_class"}
# type -> (required keys, optional keys)
_TYPE_KEYS: dict[str, tuple[set[str], set[str]]] = {
    "consecutive_nights": ({"trap_prefix", "nights"}, set()),
    "camera_ratio": ({"numerator", "denominator"}, {"min_denominator"}),
    "mean_per_unit": ({"observation"}, {"min_units"}),
    "percent_units": ({"observation"}, {"min_units"}),
    "presence": (set(), {"observation", "class"}),
}
_VALID_ACTIONS = {"ADVISORY", "SPOT_TREAT", "ALERT_ONLY"}


def load_etl(path: str | Path | None = None) -> dict[str, dict[str, Any]]:
    """Load and strictly validate etl.yaml.

    Unknown keys are errors, so a typo such as 'stict: true' fails loudly
    instead of being ignored (QA bug 10).
    """
    from .models import CLASSES  # local import: models does not need config

    cfg = _load("etl.yaml", path)
    pests = cfg.get("pests") or {}
    for key, rule in pests.items():
        where = f"pest '{key}'"
        typ = rule.get("type")
        if typ not in _TYPE_KEYS:
            raise ValueError(f"{where}: unknown type {typ!r}")
        if rule.get("action") not in _VALID_ACTIONS:
            raise ValueError(f"{where}: unknown action {rule.get('action')!r}")
        if not isinstance(rule.get("threshold"), (int, float)) or isinstance(rule.get("threshold"), bool):
            raise ValueError(f"{where}: threshold must be a number")
        required, optional = _TYPE_KEYS[typ]
        missing = required - set(rule)
        if missing:
            raise ValueError(f"{where}: missing {sorted(missing)}")
        unknown = set(rule) - _COMMON_KEYS - required - optional
        if unknown:
            raise ValueError(f"{where}: unknown keys {sorted(unknown)} (typo?)")
        if "strict" in rule and not isinstance(rule["strict"], bool):
            raise ValueError(f"{where}: strict must be true or false")
        for k in ("min_units", "min_denominator", "nights"):
            if k in rule and (not isinstance(rule[k], int) or rule[k] < 1):
                raise ValueError(f"{where}: {k} must be an integer >= 1")
        if typ == "presence":
            want = "class" if rule.get("source") == "camera_confirmed" else "observation"
            if want not in rule:
                raise ValueError(f"{where}: presence rule needs '{want}'")
        for k in ("numerator", "denominator"):
            bad = [c for c in rule.get(k, []) if c not in CLASSES]
            if bad:
                raise ValueError(f"{where}: unknown classes in {k}: {bad}")
        for k in ("locate_class", "class"):
            if k in rule and rule[k] not in CLASSES:
                raise ValueError(f"{where}: unknown class {rule[k]!r} in {k}")
    return pests
