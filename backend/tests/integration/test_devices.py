"""Farm → Device registry: provisioning, claim, ownership-scoped access, status and last-seen."""

import pytest

from gossy.ids import new_ulid
from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import FARMER_A, FARMER_B, TEST_DEVICE, bearer, login, login_admin, own_device, publish_as_test_device, wait_for, wait_ingested

pytestmark = pytest.mark.integration


def fresh_id() -> str:
    return f"itest-{new_ulid().lower()}"  # registry-only device (no broker credential needed)


async def new_farm(api, tokens, name="farm") -> str:
    r = await api.post("/api/v1/farms", json={"name": name}, headers=bearer(tokens))
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def register(api, admin, device_id) -> str:
    r = await api.post("/api/v1/admin/devices", json={"deviceId": device_id, "displayName": "Test unit"}, headers=bearer(admin))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["device"]["registrationState"] == "provisioned" and body["device"]["farmId"] is None
    return body["claimCode"]


async def test_farms_are_scoped_to_their_owner(api):
    a, b = await login(api, FARMER_A), await login(api, FARMER_B)
    farm = await new_farm(api, a, "A's farm")
    assert farm in [f["id"] for f in (await api.get("/api/v1/farms", headers=bearer(a))).json()]
    assert farm not in [f["id"] for f in (await api.get("/api/v1/farms", headers=bearer(b))).json()]
    assert (await api.get(f"/api/v1/farms/{farm}", headers=bearer(b))).status_code == 404


async def test_farm_validation(api):
    a = await login(api, FARMER_A)
    assert (await api.post("/api/v1/farms", json={"name": ""}, headers=bearer(a))).status_code == 422
    assert (await api.post("/api/v1/farms", json={"name": "x" * 81}, headers=bearer(a))).status_code == 422
    assert (await api.get("/api/v1/farms/not-a-uuid", headers=bearer(a))).status_code == 422


async def test_register_claim_and_retrieve_device(api):
    admin, a = await login_admin(api), await login(api, FARMER_A)
    device_id = fresh_id()
    code = await register(api, admin, device_id)
    farm = await new_farm(api, a)
    # Not visible to the farmer before it is claimed.
    assert (await api.get(f"/api/v1/devices/{device_id}", headers=bearer(a))).status_code == 404
    r = await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code.lower().replace("-", " "), "farmId": farm}, headers=bearer(a))
    assert r.status_code == 200, r.text
    device = r.json()
    assert device["registrationState"] == "active" and device["farmId"] == farm and device["claimedAt"]
    assert device["displayName"] == "Test unit"
    assert device["status"] == {"state": None, "stateAt": None, "lastSeenAt": None}  # never reported
    assert (await api.get(f"/api/v1/devices/{device_id}", headers=bearer(a))).json()["deviceId"] == device_id
    listed = (await api.get("/api/v1/devices", params={"farmId": farm}, headers=bearer(a))).json()
    assert [d["deviceId"] for d in listed] == [device_id]
    # Phase 5A: the reporting interval and the freshness threshold travel with every device
    # (contract values: 60 s and 180 s), so that the app hard-codes neither.
    fetched = (await api.get(f"/api/v1/devices/{device_id}", headers=bearer(a))).json()
    for body in (device, fetched, listed[0]):
        assert (body["telemetryIntervalS"], body["telemetryStaleAfterS"]) == (60, 180)


async def test_register_rejects_duplicates_and_invalid_ids(api):
    admin = await login_admin(api)
    device_id = fresh_id()
    await register(api, admin, device_id)
    assert (await api.post("/api/v1/admin/devices", json={"deviceId": device_id}, headers=bearer(admin))).status_code == 409
    for bad in ("svc-ingest", "Upper-Case", "ab", "bad/id"):
        r = await api.post("/api/v1/admin/devices", json={"deviceId": bad}, headers=bearer(admin))
        assert r.status_code == 422, (bad, r.text)


async def test_claim_code_is_secret_single_use_and_bound_to_the_device(api):
    admin, a, b = await login_admin(api), await login(api, FARMER_A), await login(api, FARMER_B)
    device_id, other_id = fresh_id(), fresh_id()
    code = await register(api, admin, device_id)
    await register(api, admin, other_id)
    farm_a, farm_b = await new_farm(api, a), await new_farm(api, b)
    # Wrong code, code of another device, and another farmer's farm are all refused.
    r = await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": "AAAA-BBBB-CCCC", "farmId": farm_a}, headers=bearer(a))
    assert r.status_code == 404 and r.json()["error"]["code"] == "claim_failed"
    r = await api.post("/api/v1/devices/claim", json={"deviceId": other_id, "claimCode": code, "farmId": farm_a}, headers=bearer(a))
    assert r.status_code == 404
    r = await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code, "farmId": farm_b}, headers=bearer(a))
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"
    assert (await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code, "farmId": farm_a}, headers=bearer(a))).status_code == 200
    # Already used: B cannot take it over with the same code.
    r = await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code, "farmId": farm_b}, headers=bearer(b))
    assert r.status_code == 404
    assert (await api.get(f"/api/v1/devices/{device_id}", headers=bearer(b))).status_code == 404
    assert device_id not in [d["deviceId"] for d in (await api.get("/api/v1/devices", headers=bearer(b))).json()]


async def test_claim_request_validation(api):
    a = await login(api, FARMER_A)
    for body in ({"deviceId": "sim-0002", "claimCode": "x", "farmId": "not-a-uuid"}, {"deviceId": "sim-0002"}, {"deviceId": "SIM", "claimCode": "AAAA-BBBB-CCCC", "farmId": "00000000-0000-0000-0000-000000000000"}):
        assert (await api.post("/api/v1/devices/claim", json=body, headers=bearer(a))).status_code == 422


async def test_reissue_detaches_and_decommission_hides_the_device(api):
    admin, a = await login_admin(api), await login(api, FARMER_A)
    device_id = fresh_id()
    code = await register(api, admin, device_id)
    farm = await new_farm(api, a)
    await api.post("/api/v1/devices/claim", json={"deviceId": device_id, "claimCode": code, "farmId": farm}, headers=bearer(a))
    r = await api.post(f"/api/v1/admin/devices/{device_id}/claim-code", headers=bearer(admin))
    assert r.status_code == 200 and r.json()["device"]["registrationState"] == "provisioned" and r.json()["claimCode"] != code
    assert (await api.get(f"/api/v1/devices/{device_id}", headers=bearer(a))).status_code == 404
    r = await api.post(f"/api/v1/admin/devices/{device_id}/decommission", headers=bearer(admin))
    assert r.status_code == 200 and r.json()["registrationState"] == "decommissioned"
    listed = (await api.get("/api/v1/admin/devices", params={"state": "decommissioned"}, headers=bearer(admin))).json()
    assert device_id in [d["deviceId"] for d in listed]
    assert (await api.post("/api/v1/admin/devices/itest-missing-device/decommission", headers=bearer(admin))).status_code == 404


async def test_device_status_and_last_seen_come_from_ingested_messages(api, engine):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    device = SimulatedDevice(TEST_DEVICE)
    messages = [device.status("online"), device.telemetry()]
    await publish_as_test_device(messages)
    await wait_ingested(engine, [m.msg_id for m in messages])

    async def online():
        status = (await api.get(f"/api/v1/devices/{TEST_DEVICE}", headers=bearer(a))).json()["status"]
        return status["state"] == "online" and status["lastSeenAt"] is not None

    await wait_for(online)
    status = (await api.get(f"/api/v1/devices/{TEST_DEVICE}", headers=bearer(a))).json()["status"]
    assert status["stateAt"] is not None


async def test_devices_endpoints_require_authentication(api):
    for path in ("/api/v1/devices", f"/api/v1/devices/{TEST_DEVICE}", "/api/v1/farms"):
        assert (await api.get(path)).status_code == 401
