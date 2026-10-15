"""Error envelope, validation details without input echo, body-size limit, safe 500s."""

from fastapi import APIRouter
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field

from gossy.api.app import create_app
from gossy.api.errors import ApiError
from gossy.config import ApiSettings, CommonSettings

router = APIRouter()


class Body(BaseModel):
    count: int = Field(ge=1)


@router.post("/_t/validate")
async def validate(body: Body):
    return {"ok": body.count}


@router.get("/_t/conflict")
async def conflict():
    raise ApiError(409, "device_exists", "Already registered.")


@router.get("/_t/boom")
async def boom():
    raise RuntimeError("secret db password=hunter2 in stack")


def client():
    app = create_app(common=CommonSettings(environment="test"), api=ApiSettings(max_request_body_bytes=2048), readiness_checks=[])
    app.include_router(router)
    return TestClient(app, raise_server_exceptions=False)


def test_api_error_envelope_has_code_message_and_request_id():
    with client() as c:
        r = c.get("/_t/conflict", headers={"X-Request-ID": "req-abcdef01"})
    assert r.status_code == 409
    assert r.json() == {"error": {"code": "device_exists", "message": "Already registered.", "requestId": "req-abcdef01"}}


def test_validation_error_lists_fields_without_echoing_input():
    with client() as c:
        r = c.post("/_t/validate", json={"count": "SECRET-INPUT"})
    body = r.json()
    assert r.status_code == 422 and body["error"]["code"] == "validation_failed"
    assert body["error"]["details"][0]["loc"] == ["body", "count"]
    assert "SECRET-INPUT" not in r.text


def test_unknown_route_uses_envelope():
    with client() as c:
        r = c.get("/api/v1/does-not-exist")
    assert r.status_code == 404 and r.json()["error"]["code"] == "not_found"


def test_unhandled_error_is_generic_500():
    with client() as c:
        r = c.get("/_t/boom")
    assert r.status_code == 500 and r.json()["error"]["code"] == "internal_error"
    assert "hunter2" not in r.text and "RuntimeError" not in r.text


def test_oversized_body_rejected_with_413():
    with client() as c:
        r = c.post("/_t/validate", content=b'{"count": 1, "pad": "' + b"x" * 4000 + b'"}', headers={"content-type": "application/json"})
    assert r.status_code == 413 and r.json()["error"]["code"] == "payload_too_large"


def test_security_headers_on_every_response():
    with client() as c:
        r = c.get("/healthz")
    assert r.headers["cache-control"] == "no-store" and r.headers["x-content-type-options"] == "nosniff"
