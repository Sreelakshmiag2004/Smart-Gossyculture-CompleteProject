import pytest
import httpx

from gossy.db.migrations import expected_head

pytestmark = pytest.mark.integration


async def test_api_liveness(api_url):
    async with httpx.AsyncClient(base_url=api_url, timeout=5) as c:
        r = await c.get("/healthz")
    assert r.status_code == 200 and r.json() == {"status": "ok"}


async def test_api_readiness_checks_database_timescale_and_migrations(api_url):
    async with httpx.AsyncClient(base_url=api_url, timeout=5) as c:
        r = await c.get("/readyz")
    body = r.json()
    assert r.status_code == 200, body
    assert body["status"] == "ready"
    # Phase 2 adds the PostgreSQL LISTEN connection that feeds the WebSocket.
    assert {k: v["ok"] for k, v in body["checks"].items()} == {"database": True, "timescaledb": True, "migrations": True, "event_listener": True}
    assert f"current={expected_head()}" in body["checks"]["migrations"]["detail"]


async def test_api_propagates_request_id(api_url):
    async with httpx.AsyncClient(base_url=api_url, timeout=5) as c:
        r = await c.get("/healthz", headers={"X-Request-ID": "itest-request-0001"})
    assert r.headers["x-request-id"] == "itest-request-0001"


async def test_ingest_service_ready_and_connected(ingest_url):
    async with httpx.AsyncClient(base_url=ingest_url, timeout=5) as c:
        r = await c.get("/readyz")
    body = r.json()
    assert r.status_code == 200, body
    assert body["checks"]["mqtt"]["ok"] and body["checks"]["database"]["ok"]
    assert body["info"]["mqtt_connect_count"] >= 1
    # Phase 2.5: "failed" (dropped after retries) no longer exists; outcomes are durable or blocked.
    assert {"received", "ingested", "duplicates", "rejected", "dead_lettered", "transient_retries", "blocked"} <= set(body["info"]["ingest"])
    assert "mqtt_acked" in body["info"]
