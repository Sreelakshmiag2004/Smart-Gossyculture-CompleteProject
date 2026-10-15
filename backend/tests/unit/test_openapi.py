"""The committed OpenAPI contract must match the code, and the API surface must stay within the
approved v1 boundary (monitoring-only; no device control)."""

import json

from gossy.api.export_openapi import build, render
from gossy.db.migrations import BACKEND_ROOT

SPEC = build()
PUBLIC = {("post", "/api/v1/auth/otp/request"), ("post", "/api/v1/auth/otp/verify"), ("post", "/api/v1/auth/refresh"), ("get", "/healthz"), ("get", "/readyz")}
# Every state-changing operation, reviewed. Adding one requires updating this list deliberately.
MUTATING = {
    ("post", "/api/v1/auth/otp/request"), ("post", "/api/v1/auth/otp/verify"), ("post", "/api/v1/auth/refresh"), ("post", "/api/v1/auth/logout"),
    ("patch", "/api/v1/me"), ("post", "/api/v1/farms"), ("post", "/api/v1/devices/claim"),
    ("post", "/api/v1/alerts/{alert_id}/acknowledge"),
    ("post", "/api/v1/admin/devices"), ("post", "/api/v1/admin/devices/{device_id}/claim-code"), ("post", "/api/v1/admin/devices/{device_id}/decommission"),
}
FORBIDDEN_WORDS = ("command", "control", "actuat", "spray-now", "harvest-now", "/pick", "/move", "/stop", "/start")


def operations():
    for path, ops in SPEC["paths"].items():
        for method, op in ops.items():
            yield method, path, op


def test_committed_openapi_matches_code():
    committed = (BACKEND_ROOT / "docs" / "openapi.json").read_text(encoding="utf-8")
    assert committed == render(), "docs/openapi.json is stale: run `python -m gossy.api.export_openapi > docs/openapi.json`"


def test_every_non_public_operation_requires_bearer_auth_and_documents_401():
    for method, path, op in operations():
        if (method, path) in PUBLIC:
            assert not op.get("security"), path
        else:
            assert op.get("security") == [{"BearerAuth": []}], (method, path)
            assert "401" in op["responses"], (method, path)


def test_state_changing_operations_are_exactly_the_reviewed_set():
    assert {(m, p) for m, p, _ in operations() if m in ("post", "put", "patch", "delete")} == MUTATING


def test_no_device_control_surface():
    for method, path, op in operations():
        text = (path + " " + op.get("summary", "") + " " + op.get("operationId", "")).lower()
        assert not any(w in text for w in FORBIDDEN_WORDS), (method, path)
    # Nothing under a specific device path can be written (admin provisioning lives under /admin).
    device_writes = [(m, p) for m, p, _ in operations() if p.startswith("/api/v1/devices/{") and m != "get"]
    assert device_writes == []


def test_error_schema_is_documented():
    assert {"ErrorResponse", "ErrorDetail"} <= set(SPEC["components"]["schemas"])
    assert json.dumps(SPEC).count('"#/components/schemas/ErrorResponse"') > 20
