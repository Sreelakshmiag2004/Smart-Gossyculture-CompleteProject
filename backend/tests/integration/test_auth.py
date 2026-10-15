"""Phone-OTP authentication (test-number mechanism), tokens, sessions and authorization boundaries."""

import pytest
from sqlalchemy import text

from tests.integration.conftest import FARMER_A, FARMER_B, FARMER_C, UNLISTED, bearer, login, login_admin, test_otp_code

pytestmark = pytest.mark.integration


def wrong_code() -> str:
    return "000000" if test_otp_code() != "000000" else "111111"


def assert_error(r, status: int, code: str):
    assert r.status_code == status, r.text
    body = r.json()
    assert set(body) == {"error"} and body["error"]["code"] == code
    assert body["error"]["requestId"] and body["error"]["message"]


async def test_successful_login_returns_tokens_and_profile(api):
    tokens = await login(api, FARMER_A)
    assert tokens["tokenType"] == "Bearer" and tokens["accessToken"] and tokens["refreshToken"]
    assert tokens["user"]["phone"] == FARMER_A and tokens["user"]["role"] == "farmer"
    r = await api.get("/api/v1/me", headers=bearer(tokens))
    assert r.status_code == 200 and r.json()["id"] == tokens["user"]["id"]


async def test_token_responses_are_not_cacheable(api):
    await api.post("/api/v1/auth/otp/request", json={"phone": FARMER_A})
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_A, "code": test_otp_code()})
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"


async def test_wrong_code_is_rejected(api):
    await api.post("/api/v1/auth/otp/request", json={"phone": FARMER_B})
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_B, "code": wrong_code()})
    assert_error(r, 401, "invalid_credentials")


async def test_code_is_single_use(api):
    await login(api, FARMER_B)
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_B, "code": test_otp_code()})
    assert_error(r, 401, "invalid_credentials")


async def test_challenge_locks_after_max_attempts(api):
    await api.post("/api/v1/auth/otp/request", json={"phone": FARMER_C})
    for _ in range(5):  # GOSSY_AUTH_OTP_MAX_ATTEMPTS default
        await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_C, "code": wrong_code()})
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_C, "code": test_otp_code()})
    assert_error(r, 401, "invalid_credentials")
    await login(api, FARMER_C)  # a new challenge works again


async def test_unlisted_number_is_not_enumerable_and_cannot_sign_in(api):
    # Same 202 answer as for an allow-listed number, but no challenge exists.
    r = await api.post("/api/v1/auth/otp/request", json={"phone": UNLISTED})
    assert r.status_code == 202 and r.json()["status"] == "accepted"
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": UNLISTED, "code": test_otp_code()})
    assert_error(r, 401, "invalid_credentials")


@pytest.mark.parametrize(
    "body",
    [{"phone": "9876543210"}, {"phone": "+99900000001", "extra": 1}, {}, {"phone": 99900000001}],
)
async def test_invalid_otp_request_is_a_validation_error(api, body):
    assert_error(await api.post("/api/v1/auth/otp/request", json=body), 422, "validation_failed")


async def test_invalid_code_format_is_a_validation_error(api):
    r = await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_A, "code": "12ab56"})
    assert_error(r, 422, "validation_failed")


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer not-a-jwt"}, {"Authorization": "Basic abc"}])
async def test_protected_endpoint_requires_valid_token(api, headers):
    r = await api.get("/api/v1/me", headers=headers)
    assert_error(r, 401, "unauthenticated")
    assert r.headers["www-authenticate"] == "Bearer"


async def test_tampered_token_is_rejected(api):
    tokens = await login(api, FARMER_A)
    head, payload, sig = tokens["accessToken"].split(".")
    tampered = f"{head}.{payload}.{sig[:-2]}{'AA' if sig[-2:] != 'AA' else 'BB'}"
    assert_error(await api.get("/api/v1/me", headers={"Authorization": f"Bearer {tampered}"}), 401, "unauthenticated")


async def test_refresh_rotates_and_reuse_revokes_the_session(api):
    first = await login(api, FARMER_A)
    r = await api.post("/api/v1/auth/refresh", json={"refreshToken": first["refreshToken"]})
    assert r.status_code == 200, r.text
    second = r.json()
    assert second["refreshToken"] != first["refreshToken"]
    assert (await api.get("/api/v1/me", headers=bearer(second))).status_code == 200
    # Replaying the rotated token = presumed theft: rejected AND the whole session is revoked.
    assert_error(await api.post("/api/v1/auth/refresh", json={"refreshToken": first["refreshToken"]}), 401, "invalid_refresh_token")
    assert_error(await api.get("/api/v1/me", headers=bearer(second)), 401, "unauthenticated")
    assert_error(await api.post("/api/v1/auth/refresh", json={"refreshToken": second["refreshToken"]}), 401, "invalid_refresh_token")


async def test_unknown_refresh_token_is_rejected(api):
    assert_error(await api.post("/api/v1/auth/refresh", json={"refreshToken": "x" * 43}), 401, "invalid_refresh_token")


async def test_logout_revokes_access_immediately(api):
    tokens = await login(api, FARMER_A)
    assert (await api.post("/api/v1/auth/logout", headers=bearer(tokens))).status_code == 204
    assert_error(await api.get("/api/v1/me", headers=bearer(tokens)), 401, "unauthenticated")
    assert_error(await api.post("/api/v1/auth/refresh", json={"refreshToken": tokens["refreshToken"]}), 401, "invalid_refresh_token")


async def test_profile_update_and_no_self_service_role_change(api):
    tokens = await login(api, FARMER_A)
    r = await api.patch("/api/v1/me", json={"displayName": "Farmer A"}, headers=bearer(tokens))
    assert r.status_code == 200 and r.json()["displayName"] == "Farmer A"
    # Unknown fields are rejected: there is no API path to become admin.
    assert_error(await api.patch("/api/v1/me", json={"displayName": "x", "role": "admin"}, headers=bearer(tokens)), 422, "validation_failed")
    assert (await api.get("/api/v1/me", headers=bearer(tokens))).json()["role"] == "farmer"


@pytest.mark.parametrize(
    "method,path",
    [("get", "/api/v1/admin/devices"), ("post", "/api/v1/admin/devices"), ("post", "/api/v1/admin/devices/sim-0002/claim-code"), ("post", "/api/v1/admin/devices/sim-0002/decommission")],
)
async def test_farmer_cannot_use_admin_endpoints(api, method, path):
    tokens = await login(api, FARMER_B)
    kwargs = {"json": {"deviceId": "itest-denied"}} if method == "post" and path.endswith("devices") else {}
    assert_error(await api.request(method, path, headers=bearer(tokens), **kwargs), 403, "forbidden")


async def test_admin_role_comes_from_the_database(api):
    admin = await login_admin(api)
    assert admin["user"]["role"] == "admin"
    assert (await api.get("/api/v1/admin/devices", headers=bearer(admin))).status_code == 200


async def test_readiness_reports_test_otp_mode(api):
    info = (await api.get("/readyz")).json()["info"]
    assert info["otpMode"] == "test"


async def test_authentication_events_are_audited_without_raw_phone_numbers(api, engine):
    await api.post("/api/v1/auth/otp/request", json={"phone": FARMER_B})
    await api.post("/api/v1/auth/otp/verify", json={"phone": FARMER_B, "code": wrong_code()}, headers={"X-Request-ID": "itest-audit-failure"})
    async with engine.connect() as conn:
        row = (await conn.execute(text("SELECT action, outcome, target, details FROM audit_log WHERE request_id = 'itest-audit-failure' ORDER BY id DESC LIMIT 1"))).one()
    assert (row.action, row.outcome, row.details["reason"]) == ("auth.login", "failure", "wrong_code")
    assert row.target != FARMER_B and row.target.endswith(FARMER_B[-2:])
