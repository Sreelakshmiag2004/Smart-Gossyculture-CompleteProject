"""Farm rules (Phase II 7b): pure logic, forecast parsing, request validation and the worker loop.
The SQL and the API are covered by tests/integration/test_farmrules.py."""

import asyncio
import uuid
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from gossy.config import FarmRulesSettings
from gossy.devices.schemas import FarmUpdate
from gossy.farmrules import logic
from gossy.farmrules.core.models import AdvisoryType, ConfirmedDetection, ManualObservation, TrapCount
from gossy.farmrules.schemas import ConfirmationIn, FarmStatus, ObservationIn, PestRule, TrapCountIn
from gossy.farmrules.weather import FarmWeather, parse, request_url
from gossy.farmrules.worker import FarmRulesWorker

NOW = datetime(2027, 1, 18, 6, 0, tzinfo=UTC)  # 11:30 IST: after the picking window's earliest hour
FARM = "f-1"
TODAY = logic.ist_today(NOW)


def scan(row, seg, opened, closed, *, hours_ago=1.0, **weather):
    data = {"row": row, "segment": seg, "counts": {"bollOpen": opened, "bollClosed": closed}, "model": "m", **weather}
    return (NOW - timedelta(hours=hours_ago), data)


def om_response(start, hours, prob, mm=0.0, temp=31.0, rh=55.0):
    times = [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M") for i in range(hours)]
    val = lambda v, i: v(i) if callable(v) else v  # noqa: E731
    return {"utc_offset_seconds": 19800, "hourly": {
        "time": times, "precipitation_probability": [val(prob, i) for i in range(hours)],
        "precipitation": [val(mm, i) for i in range(hours)], "temperature_2m": [temp] * hours, "relative_humidity_2m": [rh] * hours,
    }}


# ----------------------------------------------------------------------------- inputs
def test_scan_from_contract_event_uses_snake_case_classes_and_cart_weather():
    [s] = logic.scans_from_events(FARM, [scan(3, 2, 20, 10, airTempC=31.0, airRhPct=55.0, dewpointC=20.9)])
    assert (s.segment_key, s.counts["boll_open"], s.counts["boll_closed"], s.counts["mealybug_colony"]) == ("R003-S02", 20, 10, 0)
    assert (s.weather.t_c, s.weather.rh, s.weather.dewpoint_c) == (31.0, 55.0, 20.9)


def test_malformed_scans_are_skipped_not_fatal():
    rows = [scan(1, 1, 5, 5), (NOW, {"row": "x"}), (NOW, {"row": 1, "segment": 1, "counts": {"unknownClass": 3}})]
    assert [s.segment_key for s in logic.scans_from_events(FARM, rows)] == ["R001-S01"]


def test_zero_humidity_reading_is_not_used_as_weather():
    [s] = logic.scans_from_events(FARM, [scan(1, 1, 5, 5, airTempC=30.0, airRhPct=0.0)])
    assert s.weather is None  # dew point is undefined at 0 % RH


# ----------------------------------------------------------------------------- compute
def test_ready_segment_gives_pick_list_and_blocks_spray_advice():
    inputs = logic.FarmInputs(
        scans=logic.scans_from_events(FARM, [scan(3, 2, 20, 10, airTempC=31.0, airRhPct=55.0), scan(1, 1, 2, 30)]),
        manual=[ManualObservation(FARM, TODAY, "aphid_infested_plants", 5, 20)],  # 25 % > 10 %: ETL crossed
    )
    c = logic.compute(FARM, NOW, inputs, None)
    assert [(a.type, a.segments) for a in c.report.advisories] == [(AdvisoryType.PICK_LIST, ["R003-S02"]), (AdvisoryType.SPRAY_BLOCKED, [])]
    assert c.weather_source == "cart"
    doc = logic.status_doc(c, NOW)
    assert [(s["key"], s["status"]) for s in doc["segments"]] == [("R001-S01", "NOT_READY"), ("R003-S02", "READY")]
    assert doc["window"]["status"] == "SAFE" and doc["weather_now"]["source"] == "cart"
    aphid = next(p for p in doc["pests"] if p["pest"] == "aphid")
    assert aphid["crossed"] and aphid["value"] == 25.0
    FarmStatus.model_validate({**doc, "farm_id": uuid.uuid4()})  # the stored doc is a valid API response


def test_rain_forecast_with_ready_cotton_gives_pick_now():
    fw = parse(om_response(datetime(2027, 1, 17), 96, prob=lambda i: 85 if i == 50 else 10), NOW)
    inputs = logic.FarmInputs(scans=logic.scans_from_events(FARM, [scan(3, 2, 20, 10)]))
    c = logic.compute(FARM, NOW, inputs, fw)
    assert [a.type for a in c.report.advisories] == [AdvisoryType.PICK_NOW]
    assert c.weather_source == "forecast"  # no cart reading: the forecast model's current hour
    assert logic.status_doc(c, NOW)["rain_max_prob_48h_pct"] == 85


def test_stale_forecast_is_ignored():
    fw = parse(om_response(datetime(2027, 1, 17), 96, prob=90), NOW - timedelta(hours=4))
    c = logic.compute(FARM, NOW, logic.FarmInputs(scans=logic.scans_from_events(FARM, [scan(3, 2, 20, 10)])), fw)
    assert [a.type for a in c.report.advisories] == [AdvisoryType.PICK_LIST]
    assert c.weather is None and c.report.window is None


def test_mealybug_spot_treatment_located_by_confirmed_detections_only():
    inputs = logic.FarmInputs(
        manual=[ManualObservation(FARM, TODAY, "mealybug_grade2_plants", 5, 41)],  # 12 % of 41 plants
        confirmed=[ConfirmedDetection(FARM, 4, 1, "mealybug_colony", TODAY)],
    )
    [adv] = logic.compute(FARM, NOW, inputs, None).report.advisories
    assert (adv.type, adv.segments) == (AdvisoryType.SPOT_TREAT, ["R004-S01"])
    assert "Never spray the whole field" in adv.text_en and adv.text_ta


def test_trap_nights_and_insufficient_evidence():
    nights = [TrapCount(FARM, "PBW-1", TODAY - timedelta(days=d), 9) for d in range(3)]
    c = logic.compute(FARM, NOW, logic.FarmInputs(traps=nights), None)
    assert [a.pest for a in c.report.advisories] == ["pink_bollworm_trap"]
    whitefly = next(p for p in logic.status_doc(c, NOW)["pests"] if p["pest"] == "whitefly")
    assert whitefly["insufficient"] and not whitefly["crossed"]


def test_naive_now_is_refused():
    with pytest.raises(ValueError):
        logic.compute(FARM, NOW.replace(tzinfo=None), logic.FarmInputs(), None)


# ----------------------------------------------------------------------------- reconcile
def _active(c, **kw):
    a = c.report.advisories[0]
    return {logic.advisory_key(a): logic.ActiveAdvisory(uuid.uuid4(), logic.advisory_key(a), tuple(a.segments), a.reason, kw.get("notified_at", NOW))}


def test_reconcile_lifecycle():
    inputs = logic.FarmInputs(scans=logic.scans_from_events(FARM, [scan(3, 2, 20, 10)]))
    c = logic.compute(FARM, NOW, inputs, None)
    plan = logic.reconcile({}, c.report.advisories, NOW)
    assert [k for k, _ in plan.create] == ["PICK_LIST:crop"]
    active = _active(c)
    assert logic.reconcile(active, c.report.advisories, NOW + timedelta(hours=1)).empty  # unchanged: nothing to write
    inputs.scans += logic.scans_from_events(FARM, [scan(5, 1, 30, 5, hours_ago=0.5)])
    changed = logic.reconcile(active, logic.compute(FARM, NOW, inputs, None).report.advisories, NOW)
    assert len(changed.update) == 1 and changed.update[0][2] is False  # updated, not re-notified
    gone = logic.reconcile(active, [], NOW)
    assert gone.resolve == [next(iter(active.values())).id]


def test_pick_now_notifies_again_after_cooldown():
    fw = parse(om_response(datetime(2027, 1, 17), 96, prob=90), NOW)
    c = logic.compute(FARM, NOW, logic.FarmInputs(scans=logic.scans_from_events(FARM, [scan(3, 2, 20, 10)])), fw)
    active = _active(c, notified_at=NOW - timedelta(hours=6))
    assert logic.reconcile(active, c.report.advisories, NOW).empty
    active = _active(c, notified_at=NOW - timedelta(hours=13))
    [(_, _, renotify)] = logic.reconcile(active, c.report.advisories, NOW).update
    assert renotify


# ----------------------------------------------------------------------------- forecast
def test_forecast_parse_and_round_trip():
    resp = om_response(datetime(2027, 1, 17), 96, prob=lambda i: 80 if i == 50 else 10, mm=lambda i: 1.5 if i in (5, 30) else 0.0)
    fw = parse(resp, NOW)
    assert max(p for _, p in fw.forecast) == 80
    assert fw.rain_last_24h_mm == 1.5  # 17 Jan 05:00 IST is more than 24 h before NOW; 18 Jan 06:00 is not
    assert (fw.now_reading.t_c, fw.now_reading.rh) == (31.0, 55.0)
    assert FarmWeather.from_doc(fw.to_doc()).forecast == fw.forecast


def test_forecast_rejects_inconsistent_response():
    resp = om_response(datetime(2027, 1, 18), 5, 10)
    resp["hourly"]["precipitation"].pop()
    with pytest.raises(ValueError, match="length"):
        parse(resp, NOW)


def test_request_url():
    url = request_url(11.23, 78.88)
    for part in ("latitude=11.2300", "longitude=78.8800", "past_days=1", "precipitation_probability", "Asia%2FKolkata"):
        assert part in url


# ----------------------------------------------------------------------------- catalog and requests
def test_catalog_lists_every_rule_with_its_source_value():
    rules = [PestRule.model_validate(r) for r in logic.catalog()]
    by_pest = {r.pest: r for r in rules}
    assert by_pest["aphid"].observation == "aphid_infested_plants" and by_pest["aphid"].comparison == ">"
    assert by_pest["pink_bollworm_trap"].trap_prefix == "PBW" and by_pest["pink_bollworm_trap"].nights == 3
    assert by_pest["mealybug"].action == "SPOT_TREAT" and by_pest["leaf_curl_virus"].action == "ALERT_ONLY"
    assert logic.trap_prefixes() == {"PBW"}


def test_request_models_validate_input():
    TrapCountIn.model_validate({"trap": "pbw-2", "night": "2027-01-17", "moths": 3})
    for bad in ({"trap": "PBW", "night": "2027-01-17", "moths": 3}, {"trap": "PBW-1", "night": "2027-01-17", "moths": -1}):
        with pytest.raises(ValidationError):
            TrapCountIn.model_validate(bad)
    with pytest.raises(ValidationError):
        ObservationIn.model_validate({"observedOn": "2027-01-17", "observation": "jassid_per_leaf", "count": 3, "units": 0})
    ConfirmationIn.model_validate({"observedOn": "2027-01-17", "row": 4, "segment": 1, "className": "mealybug_colony", "verdict": "confirmed"})
    with pytest.raises(ValidationError):
        ConfirmationIn.model_validate({"observedOn": "2027-01-17", "row": 4, "segment": 1, "className": "aphid", "verdict": "confirmed"})


@pytest.mark.parametrize("body", [{}, {"latitude": 11.2}, {"latitude": 11.2, "longitude": None}, {"name": None}, {"latitude": 91, "longitude": 0}])
def test_farm_update_rejects_partial_or_invalid_location(body):
    with pytest.raises(ValidationError):
        FarmUpdate.model_validate(body)


def test_farm_update_accepts_location_pair_and_clearing():
    assert FarmUpdate.model_validate({"latitude": 11.23, "longitude": 78.88}).model_fields_set == {"latitude", "longitude"}
    FarmUpdate.model_validate({"latitude": None, "longitude": None})
    FarmUpdate.model_validate({"name": "North field"})


# ----------------------------------------------------------------------------- worker
class FakeStore:
    def __init__(self, farms, fail=()):
        self._farms, self._fail = farms, set(fail)
        self.recomputed, self.weather = [], {}

    async def farms(self):
        return self._farms

    async def save_weather(self, farm_id, fw):
        self.weather[farm_id] = fw

    async def recompute(self, farm_id, now=None):
        if farm_id in self._fail:
            raise RuntimeError("boom")
        self.recomputed.append(farm_id)


def farm_row(fid, lat=None, lon=None, fetched_at=None):
    return SimpleNamespace(id=fid, latitude=lat, longitude=lon, fetched_at=fetched_at)


def test_worker_refreshes_stale_forecasts_and_recomputes_every_farm():
    fetched = []

    async def fetch(lat, lon, now):
        fetched.append((lat, lon))
        return FarmWeather(now)

    farms = [farm_row("a", 11.0, 78.0), farm_row("b", 12.0, 79.0, NOW - timedelta(minutes=10)), farm_row("c"), farm_row("d", 13.0, 80.0, NOW - timedelta(hours=2))]
    store = FakeStore(farms)
    worker = FarmRulesWorker(store, FarmRulesSettings(), fetch, clock=lambda: NOW)
    asyncio.run(worker.run_once())
    assert fetched == [(11.0, 78.0), (13.0, 80.0)]  # b is fresh, c has no location
    assert store.recomputed == ["a", "b", "c", "d"] and set(store.weather) == {"a", "d"}


def test_worker_survives_forecast_and_farm_failures():
    async def fetch(lat, lon, now):
        raise OSError("no internet")

    store = FakeStore([farm_row("a", 11.0, 78.0), farm_row("b"), farm_row("c")], fail={"b"})
    worker = FarmRulesWorker(store, FarmRulesSettings(), fetch, clock=lambda: NOW)
    asyncio.run(worker.run_once())
    assert store.recomputed == ["a", "c"] and worker.failures == 1 and worker.runs == 1


def test_worker_without_weather_never_fetches():
    async def fetch(lat, lon, now):
        raise AssertionError("must not fetch")

    store = FakeStore([farm_row("a", 11.0, 78.0)])
    asyncio.run(FarmRulesWorker(store, FarmRulesSettings(weather_enabled=False), fetch, clock=lambda: NOW).run_once())
    assert store.recomputed == ["a"]


def test_engine_copy_is_used_for_dates_in_indian_time():
    # 20:00 UTC on 17 Jan is already 18 Jan in India: today's scouting counts must count.
    late = datetime(2027, 1, 17, 20, 0, tzinfo=UTC)
    obs = [ManualObservation(FARM, date(2027, 1, 18), "aphid_infested_plants", 5, 20)]
    c = logic.compute(FARM, late, logic.FarmInputs(manual=obs), None)
    assert [a.pest for a in c.report.advisories] == ["aphid"]
