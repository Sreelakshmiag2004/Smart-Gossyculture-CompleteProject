from fastapi.testclient import TestClient

from gossy.api.app import create_app
from gossy.config import ApiSettings, CommonSettings
from gossy.health.checks import CheckResult, named


def _check(name, ok):
    async def check():
        return CheckResult(name, ok, "detail")

    return named(name, check)


def _broken(name):
    async def check():
        raise RuntimeError("password=should-not-leak")

    return named(name, check)


def client(checks, docs=False):
    app = create_app(common=CommonSettings(environment="test", log_json=True), api=ApiSettings(docs_enabled=docs), readiness_checks=checks)
    return TestClient(app)


def test_healthz_has_no_dependencies():
    with client([_check("database", False)]) as c:
        r = c.get("/healthz")
        assert r.status_code == 200 and r.json() == {"status": "ok"}


def test_readyz_ok_when_all_checks_pass():
    with client([_check("database", True), _check("timescaledb", True)]) as c:
        r = c.get("/readyz")
        assert r.status_code == 200
        assert r.json()["status"] == "ready"
        assert set(r.json()["checks"]) == {"database", "timescaledb"}


def test_readyz_503_when_a_check_fails():
    with client([_check("database", True), _check("migrations", False)]) as c:
        r = c.get("/readyz")
        assert r.status_code == 503 and r.json()["status"] == "not_ready"


def test_readyz_exception_becomes_failed_check_without_leaking_message():
    with client([_broken("database")]) as c:
        r = c.get("/readyz")
        assert r.status_code == 503
        assert r.json()["checks"]["database"] == {"ok": False, "detail": "RuntimeError"}
        assert "should-not-leak" not in r.text


def test_request_id_generated_and_propagated():
    with client([]) as c:
        generated = c.get("/healthz").headers["x-request-id"]
        assert len(generated) == 26
        assert c.get("/healthz", headers={"X-Request-ID": "client-req-001"}).headers["x-request-id"] == "client-req-001"
        # Invalid inbound IDs are replaced, not reflected.
        assert c.get("/healthz", headers={"X-Request-ID": "<script>"}).headers["x-request-id"] != "<script>"


def test_docs_disabled_by_default():
    with client([]) as c:
        assert c.get("/docs").status_code == 404
        assert c.get("/openapi.json").status_code == 404


def test_docs_can_be_enabled_for_development():
    with client([], docs=True) as c:
        assert c.get("/openapi.json").status_code == 200
