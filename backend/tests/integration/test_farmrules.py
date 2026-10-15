"""Farm rules (Phase II 7b) end to end: data entry and cart scans -> advice and farm status;
farm location; operator access. The rules are re-run by the API after each entry (the worker
is not needed for these tests)."""

import random
from datetime import UTC, datetime, timedelta, timezone

import pytest

from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import (
    FARMER_A, FARMER_B, FARMER_C, TEST_DEVICE, bearer, login, login_admin, own_device, publish_as_test_device, wait_ingested,
)

pytestmark = pytest.mark.integration
IST = timezone(timedelta(hours=5, minutes=30))


def today():
    return datetime.now(UTC).astimezone(IST).date()


def day(offset: int = 0) -> str:
    return (today() + timedelta(days=offset)).isoformat()


async def new_farm(api, tokens, name="rules farm") -> str:
    r = await api.post("/api/v1/farms", json={"name": name}, headers=bearer(tokens))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def post(api, tokens, path, body, status=201):
    r = await api.post(path, json=body, headers=bearer(tokens))
    assert r.status_code == status, r.text
    return r.json() if r.content else None


async def advisories(api, tokens, farm, **params):
    r = await api.get(f"/api/v1/farms/{farm}/advisories", params={"limit": 1000, **params}, headers=bearer(tokens))
    assert r.status_code == 200, r.text
    return r.json()["items"]


async def active_by_pest(api, tokens, farm):
    return {a["pest"] or "crop": a for a in await advisories(api, tokens, farm, active="true")}


async def status(api, tokens, farm):
    r = await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(tokens))
    assert r.status_code == 200, r.text
    return r.json()


def pest(st, name):
    return next(p for p in st["pests"] if p["pest"] == name)


# ----------------------------------------------------------------------------- farm and access
async def test_farm_location_and_owner_only_changes(api):
    a, b = await login(api, FARMER_A), await login(api, FARMER_B)
    farm = await new_farm(api, a)
    r = await api.patch(f"/api/v1/farms/{farm}", json={"latitude": 11.23, "longitude": 78.88}, headers=bearer(a))
    assert r.status_code == 200, r.text
    assert (r.json()["latitude"], r.json()["longitude"], r.json()["access"]) == (11.23, 78.88, "owner")
    assert (await api.patch(f"/api/v1/farms/{farm}", json={"latitude": 11.2}, headers=bearer(a))).status_code == 422
    assert (await api.patch(f"/api/v1/farms/{farm}", json={"name": "x"}, headers=bearer(b))).status_code == 404
    listed = {f["id"]: f for f in (await api.get("/api/v1/farms", headers=bearer(a))).json()}
    assert listed[farm]["latitude"] == 11.23
    r = await api.patch(f"/api/v1/farms/{farm}", json={"latitude": None, "longitude": None}, headers=bearer(a))
    assert r.status_code == 200 and r.json()["latitude"] is None


async def test_operator_enters_data_but_cannot_manage_the_farm_or_see_devices(api):
    a, b, c, admin = await login(api, FARMER_A), await login(api, FARMER_B), await login(api, FARMER_C), await login_admin(api)
    farm = await new_farm(api, a)
    member = await post(api, a, f"/api/v1/farms/{farm}/members", {"phone": FARMER_C})
    assert (member["phone"], member["role"]) == (FARMER_C, "operator")
    assert (await api.post(f"/api/v1/farms/{farm}/members", json={"phone": FARMER_A}, headers=bearer(a))).status_code == 422

    farms_c = {f["id"]: f["access"] for f in (await api.get("/api/v1/farms", headers=bearer(c))).json()}
    assert farms_c[farm] == "operator"
    assert (await api.get(f"/api/v1/farms/{farm}", headers=bearer(c))).json()["access"] == "operator"
    await post(api, c, f"/api/v1/farms/{farm}/observations", {"observedOn": day(), "observation": "jassid_per_leaf", "count": 10, "units": 25})
    assert (await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(c))).status_code == 200
    # Owner-only actions are refused (403: the operator knows the farm exists).
    assert (await api.patch(f"/api/v1/farms/{farm}", json={"name": "mine now"}, headers=bearer(c))).status_code == 403
    assert (await api.get(f"/api/v1/farms/{farm}/members", headers=bearer(c))).status_code == 403
    assert (await api.post(f"/api/v1/farms/{farm}/members", json={"phone": FARMER_B}, headers=bearer(c))).status_code == 403
    assert (await api.get("/api/v1/devices", params={"farmId": farm}, headers=bearer(c))).json() == []
    # Strangers see nothing; admins may read but not enter data.
    assert (await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(b))).status_code == 404
    assert (await api.post(f"/api/v1/farms/{farm}/traps", json={"trap": "PBW-1", "night": day(), "moths": 1}, headers=bearer(b))).status_code == 404
    assert (await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(admin))).status_code == 200
    assert (await api.post(f"/api/v1/farms/{farm}/traps", json={"trap": "PBW-1", "night": day(), "moths": 1}, headers=bearer(admin))).status_code == 403

    members = (await api.get(f"/api/v1/farms/{farm}/members", headers=bearer(a))).json()
    assert [m["userId"] for m in members] == [member["userId"]]
    assert (await api.delete(f"/api/v1/farms/{farm}/members/{member['userId']}", headers=bearer(a))).status_code == 204
    assert (await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(c))).status_code == 404
    assert (await api.delete(f"/api/v1/farms/{farm}/members/{member['userId']}", headers=bearer(a))).status_code == 404


# ----------------------------------------------------------------------------- scouting and traps
async def test_scouting_count_crosses_the_threshold_and_a_newer_sample_clears_it(api):
    a = await login(api, FARMER_A)
    farm = await new_farm(api, a)
    obs = await post(api, a, f"/api/v1/farms/{farm}/observations", {"observedOn": day(-1), "observation": "aphid_infested_plants", "count": 5, "units": 20})
    assert obs["pest"] == "aphid"
    adv = (await active_by_pest(api, a, farm))["aphid"]
    assert adv["type"] == "PEST_ETL" and adv["textEn"] and adv["textTa"]  # no ready cotton: plain advice
    st = await status(api, a, farm)
    assert pest(st, "aphid")["crossed"] and pest(st, "aphid")["value"] == 25.0 and st["computedAt"]
    # A newer sample below the threshold (1 of 20 = 5 %) clears it; the old advice becomes history.
    await post(api, a, f"/api/v1/farms/{farm}/observations", {"observedOn": day(), "observation": "aphid_infested_plants", "count": 1, "units": 20})
    assert "aphid" not in await active_by_pest(api, a, farm)
    [old] = [x for x in await advisories(api, a, farm, active="false") if x["id"] == adv["id"]]
    assert old["resolvedAt"] and not old["active"]
    listed = (await api.get(f"/api/v1/farms/{farm}/observations", headers=bearer(a))).json()
    assert [o["observedOn"] for o in listed] == [day(), day(-1)]


async def test_mealybug_spot_treatment_is_located_by_confirmed_detections(api):
    a = await login(api, FARMER_A)
    farm = await new_farm(api, a)
    obs = await post(api, a, f"/api/v1/farms/{farm}/observations", {"observedOn": day(), "observation": "mealybug_grade2_plants", "count": 5, "units": 41})
    adv = (await active_by_pest(api, a, farm))["mealybug"]
    assert (adv["type"], adv["segments"]) == ("SPOT_TREAT", [])
    await post(api, a, f"/api/v1/farms/{farm}/confirmations", {"observedOn": day(), "row": 4, "segment": 1, "className": "mealybug_colony", "verdict": "confirmed"})
    await post(api, a, f"/api/v1/farms/{farm}/confirmations", {"observedOn": day(), "row": 5, "segment": 1, "className": "mealybug_colony", "verdict": "rejected"})
    adv = (await active_by_pest(api, a, farm))["mealybug"]
    assert adv["segments"] == ["R004-S01"]  # the rejected detection is not a location
    # Removing the field sample removes the reason to treat, even with a confirmed location.
    assert (await api.delete(f"/api/v1/farms/{farm}/observations/{obs['id']}", headers=bearer(a))).status_code == 204
    assert "mealybug" not in await active_by_pest(api, a, farm)
    assert (await api.delete(f"/api/v1/farms/{farm}/observations/{obs['id']}", headers=bearer(a))).status_code == 404


async def test_trap_counts_need_three_nights_and_a_correction_replaces_a_count(api):
    a = await login(api, FARMER_A)
    farm = await new_farm(api, a)
    for offset in (-2, -1, 0):
        await post(api, a, f"/api/v1/farms/{farm}/traps", {"trap": "pbw-1", "night": day(offset), "moths": 9})
    assert (await active_by_pest(api, a, farm))["pink_bollworm_trap"]["type"] == "PEST_ETL"
    fixed = await post(api, a, f"/api/v1/farms/{farm}/traps", {"trap": "PBW-1", "night": day(), "moths": 2})
    nights = (await api.get(f"/api/v1/farms/{farm}/traps", headers=bearer(a))).json()
    assert [(t["night"], t["moths"]) for t in nights] == [(day(), 2), (day(-1), 9), (day(-2), 9)]
    assert nights[0]["id"] == fixed["id"] and fixed["trap"] == "PBW-1"
    assert "pink_bollworm_trap" not in await active_by_pest(api, a, farm)


async def test_data_entry_validation(api):
    a = await login(api, FARMER_A)
    farm = await new_farm(api, a)
    path = f"/api/v1/farms/{farm}"
    cases = [
        ("/observations", {"observedOn": day(), "observation": "aphids_everywhere", "count": 1, "units": 20}, "unknown_observation"),
        ("/observations", {"observedOn": day(), "observation": "aphid_infested_plants", "count": 21, "units": 20}, "count_exceeds_units"),
        ("/observations", {"observedOn": day(), "observation": "jassid_per_leaf", "count": 3, "units": 25, "row": 2}, "invalid_location"),
        ("/observations", {"observedOn": day(1), "observation": "jassid_per_leaf", "count": 3, "units": 25}, "invalid_date"),
        ("/traps", {"trap": "XYZ-1", "night": day(), "moths": 1}, "unknown_trap_type"),
        ("/traps", {"trap": "PBW-1", "night": day(-61), "moths": 1}, "invalid_date"),
        ("/confirmations", {"observedOn": day(), "row": 1, "segment": 1, "className": "aphid", "verdict": "confirmed"}, "validation_failed"),
    ]
    for suffix, body, code in cases:
        r = await api.post(path + suffix, json=body, headers=bearer(a))
        assert r.status_code == 422 and r.json()["error"]["code"] == code, (body, r.text)


# ----------------------------------------------------------------------------- cart scans
async def test_cart_scans_give_segment_readiness_pick_list_and_block_spraying(api, engine):
    a = await login(api, FARMER_A)
    farm = await own_device(api, a)
    row = random.randint(100, 9000)  # unique segments: earlier scans of the test device may exist
    device = SimulatedDevice(TEST_DEVICE)
    ready = device.scan(row, 1, counts={"bollOpen": 20, "bollClosed": 10})
    green = device.scan(row, 2, counts={"bollOpen": 1, "bollClosed": 30})
    await publish_as_test_device([ready, green])
    await wait_ingested(engine, [ready.msg_id, green.msg_id])

    r = await api.post(f"/api/v1/farms/{farm}/status/recompute", headers=bearer(a))
    assert r.status_code == 200, r.text
    segments = {s["key"]: s for s in r.json()["segments"]}
    key1, key2 = f"R{row:03d}-S01", f"R{row:03d}-S02"
    assert (segments[key1]["status"], segments[key1]["readiness"], segments[key1]["openBolls"]) == ("READY", 0.6667, 20)
    assert segments[key2]["status"] == "NOT_READY" and (segments[key2]["row"], segments[key2]["segment"]) == (row, 2)
    pick = (await active_by_pest(api, a, farm))["crop"]
    assert pick["type"] in ("PICK_LIST", "PICK_NOW") and key1 in pick["segments"] and key2 not in pick["segments"]
    # A pest threshold crossed while cotton is ready to pick: pick first, no spray advice.
    await post(api, a, f"/api/v1/farms/{farm}/observations", {"observedOn": day(), "observation": "aphid_infested_plants", "count": 5, "units": 20})
    assert (await active_by_pest(api, a, farm))["aphid"]["type"] == "SPRAY_BLOCKED"


# ----------------------------------------------------------------------------- catalog and auth
async def test_catalog_and_authentication(api):
    a = await login(api, FARMER_A)
    rules = {r["pest"]: r for r in (await api.get("/api/v1/farm-rules/catalog", headers=bearer(a))).json()}
    assert rules["aphid"]["observation"] == "aphid_infested_plants" and rules["aphid"]["threshold"] == 10.0
    assert rules["pink_bollworm_trap"]["trapPrefix"] == "PBW"
    farm = await new_farm(api, a)
    for path in ("/api/v1/farm-rules/catalog", f"/api/v1/farms/{farm}/status", f"/api/v1/farms/{farm}/advisories", f"/api/v1/farms/{farm}/traps"):
        assert (await api.get(path)).status_code == 401
    st = (await api.get(f"/api/v1/farms/{farm}/status", headers=bearer(a))).json()
    assert st["farmId"] == farm  # never computed or computed with no data: no segments, no window
    assert st["segments"] == [] and st["window"] is None
