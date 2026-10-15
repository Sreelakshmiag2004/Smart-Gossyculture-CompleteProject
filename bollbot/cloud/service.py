"""Farm rules service: recompute one farm's advisories (spec Sections 4, 11).

Storage-independent: all data access goes through the `Repo` interface, so
it is tested with an in-memory repo, used by cloud/local.py, and backed by
PostgreSQL in the backend (Module 7b). The collection names below are the
logical record types; the backend maps them to its tables.

Logical layout (all records carry a 'farm' field where relevant):
  farms/{farm}            name, lat, lon, fpo
  users/{uid}             role (farmer | operator | fpo_manager), farms [..], lang (ta | en), fcm_tokens [..]
  scans/{scanId}          written by the cart (Module 3)
  traps/{id}              pheromone / sticky trap counts (app)
  observations/{id}       manual scouting counts (app)
  confirmations/{id}      human-confirmed detections (app)
  weather/{farm}          cached Open-Meteo forecast (this module)
  advisories/{key}        current and past advice (this module; app reads)
  farm_status/{farm}      segment readiness map, picking window, pest status (this module)
  devices/, spray_events/, pick_attempts/   from the cart
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Callable, Optional, Protocol

from bollbot.core.engine import FarmReport, run_farm
from bollbot.core.models import (Advisory, AdvisoryType, ConfirmedDetection, ManualObservation,
                                 SegmentScan, TrapCount, WeatherReading)
from bollbot.core.rules import IST
from .weather import FarmWeather

log = logging.getLogger(__name__)

HISTORY_DAYS = 14                  # data older than this is ignored
WEATHER_MAX_AGE = timedelta(hours=3)
CART_WEATHER_MAX_AGE = timedelta(hours=2)
NOTIFY_COOLDOWN = timedelta(hours=12)
# Advisory types that notify again after the cooldown while still active
RENOTIFY = {AdvisoryType.PICK_NOW}


class Repo(Protocol):
    def farm(self, farm: str) -> Optional[dict]: ...
    def by_farm(self, collection: str, farm: str) -> list[dict]: ...
    def weather(self, farm: str) -> Optional[dict]: ...
    def put_weather(self, farm: str, doc: dict) -> None: ...
    def advisories(self, farm: str) -> dict[str, dict]: ...        # key -> doc (active only)
    def put_advisory(self, key: str, doc: dict) -> None: ...
    def put_status(self, farm: str, doc: dict) -> None: ...
    def recipients(self, farm: str) -> list[tuple[str, str]]: ...   # (fcm token, lang)
    def farms(self) -> list[str]: ...


Notifier = Callable[[list[dict]], None]        # list of {"token","title","body","data"}


# ----------------------------------------------------------- loading data
def _load(docs: list[dict], parse, label: str, keep: Callable) -> list:
    out = []
    for d in docs:
        try:
            obj = parse(d)
        except (KeyError, TypeError, ValueError) as e:
            log.warning("skipping malformed %s %s: %s", label, d.get("_id", "?"), e)
            continue
        if keep(obj):
            out.append(obj)
    return out


def _aware(dt: datetime) -> datetime:
    """Treat naive timestamps as IST (the cart and app write IST)."""
    return dt if dt.tzinfo else dt.replace(tzinfo=IST)


def _scan(d: dict) -> SegmentScan:
    s = SegmentScan.from_dict(d)
    s.ts = _aware(s.ts)
    return s


def _confirmation(d: dict) -> ConfirmedDetection:
    from datetime import date
    return ConfirmedDetection(d["farm"], int(d["row"]), int(d["segment"]), d["class"],
                              date.fromisoformat(d["date"]))


# ------------------------------------------------------------- advisories
def advisory_key(a: Advisory) -> str:
    """One document per farm, type and pest: it is updated while the
    condition lasts and marked inactive when it clears."""
    return f"{a.farm}_{a.type.value}_{a.pest or 'crop'}"


@dataclass
class Reconciled:
    writes: dict[str, dict] = field(default_factory=dict)    # key -> full doc
    notify: list[str] = field(default_factory=list)          # keys to notify


def reconcile(existing: dict[str, dict], new: list[Advisory], now: datetime) -> Reconciled:
    """Compare the engine's advisories with the active ones in Firestore.

    - new key                     -> create, notify
    - same key, changed segments or reason -> update
    - PICK_NOW still active after the 12 h cooldown -> update and notify again
    - same key, unchanged         -> no write (saves Firestore writes)
    - active key not produced now -> resolve (active = false)
    """
    out = Reconciled()
    now_s = now.isoformat()
    seen = set()
    for a in new:
        key = advisory_key(a)
        seen.add(key)
        doc = {**a.to_dict(), "key": key, "active": True, "updated": now_s}
        old = existing.get(key)
        if old is None:
            doc.update(created=now_s, notified_at=now_s)
            out.writes[key] = doc
            out.notify.append(key)
            continue
        doc["created"] = old.get("created", now_s)
        doc["notified_at"] = old.get("notified_at")
        last = datetime.fromisoformat(old["notified_at"]) if old.get("notified_at") else None
        changed = sorted(old.get("segments", [])) != sorted(a.segments) or old.get("reason") != a.reason
        cooled = last is None or now - last >= NOTIFY_COOLDOWN
        renotify = a.type in RENOTIFY and cooled
        if renotify:
            doc["notified_at"] = now_s
            out.notify.append(key)
        if changed or renotify:
            out.writes[key] = doc
    for key, old in existing.items():
        if key not in seen and old.get("active"):
            out.writes[key] = {**old, "active": False, "resolved_at": now_s, "updated": now_s}
    return out


TITLES = {
    "PICK_NOW": ("Pick now – rain coming", "இப்போதே பறிக்கவும் – மழை வருகிறது"),
    "PICK_LIST": ("Cotton ready to pick", "பருத்தி பறிக்கத் தயார்"),
    "PEST_ETL": ("Pest threshold crossed", "பூச்சி சேத நிலை தாண்டியது"),
    "SPOT_TREAT": ("Spot treatment needed", "குறிப்பிட்ட இடத்தில் சிகிச்சை தேவை"),
    "PEST_ALERT": ("Disease alert", "நோய் எச்சரிக்கை"),
    "SPRAY_BLOCKED": ("Pest found – pick first", "பூச்சி கண்டறியப்பட்டது – முதலில் பறிக்கவும்"),
}


def build_messages(docs: list[dict], recipients: list[tuple[str, str]]) -> list[dict]:
    """One push message per (advisory, phone), in the phone owner's language."""
    msgs = []
    for d in docs:
        en_title, ta_title = TITLES.get(d["type"], ("BollBot", "பால்பாட்"))
        for token, lang in recipients:
            ta = lang == "ta"
            msgs.append({"token": token, "title": ta_title if ta else en_title,
                         "body": (d.get("text_ta") if ta else d.get("text_en")) or d.get("text_en", ""),
                         "data": {"key": d["key"], "farm": d["farm"], "type": d["type"]}})
    return msgs


# --------------------------------------------------------------- recompute
def weather_for(repo: Repo, farm_doc: dict, farm: str, now: datetime,
                fetch: Optional[Callable[[float, float, datetime], FarmWeather]]) -> Optional[FarmWeather]:
    """Cached forecast if fresh, else fetch (if a fetcher is given and the farm has coordinates)."""
    cached = repo.weather(farm)
    if cached:
        try:
            fw = FarmWeather.from_doc(cached)
            if now - _aware(fw.fetched) <= WEATHER_MAX_AGE:
                return fw
        except (KeyError, ValueError) as e:
            log.warning("bad weather cache for %s: %s", farm, e)
    if fetch is None or farm_doc.get("lat") is None or farm_doc.get("lon") is None:
        return None
    try:
        fw = fetch(float(farm_doc["lat"]), float(farm_doc["lon"]), now)
    except Exception as e:  # noqa: BLE001 - no forecast must not stop pest advice
        log.warning("weather fetch failed for %s: %s", farm, e)
        return None
    repo.put_weather(farm, fw.to_doc())
    return fw


def recompute_farm(repo: Repo, farm: str, now: datetime, thresholds: dict, pests: dict,
                   notifier: Optional[Notifier] = None,
                   fetch: Optional[Callable[[float, float, datetime], FarmWeather]] = None) -> FarmReport:
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    farm_doc = repo.farm(farm) or {}
    since = now - timedelta(days=HISTORY_DAYS)
    since_day = since.astimezone(IST).date()
    scans = _load(repo.by_farm("scans", farm), _scan, "scan", lambda s: s.ts >= since)
    traps = _load(repo.by_farm("traps", farm), TrapCount.from_dict, "trap", lambda t: t.date >= since_day)
    manual = _load(repo.by_farm("observations", farm), ManualObservation.from_dict, "observation",
                   lambda m: m.date >= since_day)
    confirmed = _load(repo.by_farm("confirmations", farm), _confirmation, "confirmation",
                      lambda c: c.date >= since_day)

    fw = weather_for(repo, farm_doc, farm, now, fetch)
    # Picking window: the cart's own sensor if it read recently, else the forecast model.
    recent = [s for s in scans if s.weather and now - s.ts <= CART_WEATHER_MAX_AGE]
    weather_now = max(recent, key=lambda s: s.ts).weather if recent else (fw.now_reading if fw else None)

    report = run_farm(farm, now, thresholds, pests, scans=scans, traps=traps, manual=manual,
                      confirmed=confirmed, weather_now=weather_now,
                      rain_last_24h_mm=fw.rain_last_24h_mm if fw else 0.0,
                      forecast=fw.forecast if fw else ())

    rec = reconcile(repo.advisories(farm), report.advisories, now)
    for key, doc in rec.writes.items():
        repo.put_advisory(key, doc)
    if notifier and rec.notify:
        msgs = build_messages([rec.writes[k] for k in rec.notify], repo.recipients(farm))
        if msgs:
            try:
                notifier(msgs)
            except Exception as e:  # noqa: BLE001 - advice is saved even if a push fails
                log.warning("push failed for %s: %s", farm, e)

    repo.put_status(farm, status_doc(report, fw, weather_now, now))
    return report


def status_doc(report: FarmReport, fw: Optional[FarmWeather], weather_now, now: datetime) -> dict:
    w = report.window
    return {
        "farm": report.farm, "updated": now.isoformat(),
        "segments": [{"segment": s.segment, "readiness": s.readiness, "status": s.status.value,
                      "open_bolls": s.open_bolls, "scanned": s.scanned.isoformat()}
                     for s in report.segments],
        "window": None if w is None else {"status": w.status.value, "dewpoint_c": w.dewpoint_c,
                                          "dewpoint_depression_c": w.dewpoint_depression_c,
                                          "failed": w.failed},
        "weather_now": weather_now.to_dict() if weather_now else None,
        "weather_source": None if weather_now is None else
        ("forecast" if fw and weather_now is fw.now_reading else "cart"),
        "rain_last_24h_mm": fw.rain_last_24h_mm if fw else None,
        "rain_max_prob_48h": max((p for t, p in fw.forecast if t <= now + timedelta(hours=48)), default=None)
        if fw else None,
        "pests": [{"pest": f.pest, "crossed": f.crossed, "insufficient": f.insufficient,
                   "value": f.value, "threshold": f.threshold, "detail": f.detail} for f in report.findings],
    }


class InMemoryRepo:
    """Repo for tests and local runs."""

    def __init__(self):
        self.docs: dict[str, dict[str, dict]] = {}

    def add(self, collection: str, doc_id: str, doc: dict) -> None:
        self.docs.setdefault(collection, {})[doc_id] = {**doc, "_id": doc_id}

    def farm(self, farm):
        return self.docs.get("farms", {}).get(farm)

    def by_farm(self, collection, farm):
        return [d for d in self.docs.get(collection, {}).values() if d.get("farm") == farm]

    def weather(self, farm):
        return self.docs.get("weather", {}).get(farm)

    def put_weather(self, farm, doc):
        self.add("weather", farm, doc)

    def advisories(self, farm):
        return {k: d for k, d in self.docs.get("advisories", {}).items()
                if d.get("farm") == farm and d.get("active")}

    def put_advisory(self, key, doc):
        self.add("advisories", key, doc)

    def put_status(self, farm, doc):
        self.add("farm_status", farm, doc)

    def recipients(self, farm):
        out = []
        for u in self.docs.get("users", {}).values():
            if farm in u.get("farms", []):
                out += [(t, u.get("lang", "ta")) for t in u.get("fcm_tokens", [])]
        return out

    def farms(self):
        return sorted(self.docs.get("farms", {}))
