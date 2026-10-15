"""Alerts: created by ingest from device messages (exactly once), retrieval, filtering,
acknowledgement and authorization."""

import pytest
from sqlalchemy import text

from gossy_sim.device import SimulatedDevice
from tests.integration.conftest import FARMER_A, FARMER_B, TEST_DEVICE, bearer, login, own_device, publish_as_test_device, wait_ingested

pytestmark = pytest.mark.integration


async def alerts_for(api, tokens, msg_id, **params):
    r = await api.get("/api/v1/alerts", params={"deviceId": TEST_DEVICE, "limit": 1000, **params}, headers=bearer(tokens))
    assert r.status_code == 200, r.text
    return [a for a in r.json()["items"] if a["sourceMsgId"] == msg_id]


@pytest.fixture
async def published(api, engine):
    a = await login(api, FARMER_A)
    await own_device(api, a)
    device = SimulatedDevice(TEST_DEVICE)
    pest = device.pest()
    spray = device.spray(related_msg_id=pest.msg_id)
    offline = device.status("offline")
    telemetry = device.telemetry()
    # The pest message is delivered twice: the alert must still be created once.
    messages = [pest, pest, spray, telemetry, offline]
    await publish_as_test_device(messages)
    await wait_ingested(engine, [pest.msg_id, spray.msg_id, offline.msg_id, telemetry.msg_id])
    return {"a": a, "pest": pest, "spray": spray, "offline": offline, "telemetry": telemetry}


async def test_alerts_are_created_from_device_messages(api, published):
    a = published["a"]
    [pest] = await alerts_for(api, a, published["pest"].msg_id)
    assert (pest["type"], pest["severity"], pest["status"]) == ("pest_detected", "warning", "open")
    assert set(pest["details"]) == {"label", "confidence"}
    [spray] = await alerts_for(api, a, published["spray"].msg_id)
    assert (spray["type"], spray["severity"]) == ("spray_performed", "info")
    assert spray["details"]["relatedMsgId"] == published["pest"].msg_id
    [offline] = await alerts_for(api, a, published["offline"].msg_id)
    assert (offline["type"], offline["severity"]) == ("device_offline", "warning")
    assert await alerts_for(api, a, published["telemetry"].msg_id) == []  # no invented thresholds


async def test_duplicate_delivery_creates_one_alert(published, engine):
    async with engine.connect() as conn:
        n = (await conn.execute(text("SELECT count(*) FROM alerts WHERE source_msg_id = :m"), {"m": published["pest"].msg_id})).scalar()
    assert n == 1


async def test_alert_filters_and_retrieval(api, published):
    a = published["a"]
    assert await alerts_for(api, a, published["pest"].msg_id, type="spray_performed") == []
    assert len(await alerts_for(api, a, published["pest"].msg_id, type="pest_detected", status="open")) == 1
    [alert] = await alerts_for(api, a, published["pest"].msg_id)
    r = await api.get(f"/api/v1/alerts/{alert['id']}", headers=bearer(a))
    assert r.status_code == 200 and r.json() == alert
    # Unscoped list contains the caller's alerts.
    r = await api.get("/api/v1/alerts", params={"limit": 1000}, headers=bearer(a))
    assert alert["id"] in [x["id"] for x in r.json()["items"]]


async def test_acknowledge_is_idempotent(api, published):
    a = published["a"]
    [alert] = await alerts_for(api, a, published["spray"].msg_id)
    r1 = await api.post(f"/api/v1/alerts/{alert['id']}/acknowledge", headers=bearer(a))
    assert r1.status_code == 200 and r1.json()["status"] == "acknowledged" and r1.json()["acknowledgedAt"]
    r2 = await api.post(f"/api/v1/alerts/{alert['id']}/acknowledge", headers=bearer(a))
    assert r2.status_code == 200 and r2.json()["acknowledgedAt"] == r1.json()["acknowledgedAt"]
    assert await alerts_for(api, a, published["spray"].msg_id, status="open") == []


async def test_other_farmer_cannot_see_or_acknowledge(api, published):
    a, b = published["a"], await login(api, FARMER_B)
    [alert] = await alerts_for(api, a, published["pest"].msg_id)
    assert (await api.get(f"/api/v1/alerts/{alert['id']}", headers=bearer(b))).status_code == 404
    assert (await api.post(f"/api/v1/alerts/{alert['id']}/acknowledge", headers=bearer(b))).status_code == 404
    assert (await api.get("/api/v1/alerts", params={"deviceId": TEST_DEVICE}, headers=bearer(b))).status_code == 404
    unscoped = (await api.get("/api/v1/alerts", params={"limit": 1000}, headers=bearer(b))).json()["items"]
    assert alert["id"] not in [x["id"] for x in unscoped]
    # Still open for the owner.
    assert (await api.get(f"/api/v1/alerts/{alert['id']}", headers=bearer(a))).json()["status"] == "open"


@pytest.mark.parametrize("params", [{"status": "closed"}, {"type": "low_battery"}, {"limit": 0}, {"cursor": "%%%"}])
async def test_alert_query_validation(api, params):
    a = await login(api, FARMER_A)
    assert (await api.get("/api/v1/alerts", params=params, headers=bearer(a))).status_code == 422


async def test_alerts_require_authentication_and_valid_ids(api):
    assert (await api.get("/api/v1/alerts")).status_code == 401
    a = await login(api, FARMER_A)
    assert (await api.get("/api/v1/alerts/not-a-uuid", headers=bearer(a))).status_code == 422
    assert (await api.get("/api/v1/alerts/00000000-0000-0000-0000-000000000000", headers=bearer(a))).status_code == 404
