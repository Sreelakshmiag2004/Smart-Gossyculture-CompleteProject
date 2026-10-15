"""Deployment configuration validation (python -m gossy.prodcheck)."""

import os
import secrets

import pytest

from gossy import prodcheck


@pytest.fixture
def prod_env(tmp_path, monkeypatch):
    for key in list(os.environ):
        if key.startswith("GOSSY_"):
            monkeypatch.delenv(key)

    def secret(name, value=None):
        p = tmp_path / name
        p.write_text(value or secrets.token_urlsafe(40))
        return str(p)

    ca = tmp_path / "ca.crt"
    ca.write_text("-----BEGIN CERTIFICATE-----\npublic CA bundle\n-----END CERTIFICATE-----\n")
    env = {
        "GOSSY_ENVIRONMENT": "production", "GOSSY_DB_HOST": "timescaledb", "GOSSY_DB_NAME": "gossy", "GOSSY_DB_USER": "gossy_app",
        "GOSSY_DB_PASSWORD_FILE": secret("db"), "GOSSY_AUTH_JWT_SIGNING_KEY_FILE": secret("jwt"), "GOSSY_AUTH_OTP_HMAC_KEY_FILE": secret("hmac"),
        "GOSSY_MQTT_HOST": "mqtt.example-owner.in", "GOSSY_MQTT_CLIENT_ID": "svc-ingest-1", "GOSSY_MQTT_USERNAME": "svc-ingest",
        "GOSSY_MQTT_PASSWORD_FILE": secret("mqtt"), "GOSSY_MQTT_CA_FILE": str(ca),
        "GOSSY_API_PUBLIC_HOST": "api.gossy-owner.in", "GOSSY_MQTT_PUBLIC_HOST": "mqtt.gossy-owner.in", "GOSSY_IMAGE_TAG": "0.3.0-20260930",
        "GOSSY_TLS_PROFILE": "acme", "GOSSY_ACME_EMAIL": "ops@gossy-owner.in",
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    return tmp_path, monkeypatch


def failed(checks):
    return {name for name, ok, _ in checks if not ok}


def test_valid_production_configuration_passes(prod_env):
    assert failed(prodcheck.run()) == set()


def test_test_otp_mode_fails_in_production(prod_env):
    tmp, mp = prod_env
    (tmp / "code").write_text("123456")
    mp.setenv("GOSSY_AUTH_TEST_MODE", "true")
    mp.setenv("GOSSY_AUTH_TEST_PHONE_NUMBERS", "+99900000001")
    mp.setenv("GOSSY_AUTH_TEST_OTP_CODE_FILE", str(tmp / "code"))
    assert {"service startup rules", "OTP test mode off in production"} <= failed(prodcheck.run())


def test_development_secrets_and_ca_fail(prod_env):
    tmp, mp = prod_env
    (tmp / "db").write_text("devonly-" + "x" * 30)
    (tmp / "ca.crt").write_text("Smart Gossyculture DEV CA - NOT FOR PRODUCTION")
    (tmp / "DEVELOPMENT_ONLY").write_text("dev")
    assert {"database password", "MQTT CA is not the development CA", "service startup rules", "no development-secret marker next to secrets"} <= failed(prodcheck.run())


def test_docs_injection_placeholder_domain_and_unpinned_tag_fail(prod_env):
    tmp, mp = prod_env
    mp.setenv("GOSSY_API_DOCS_ENABLED", "true")
    mp.setenv("GOSSY_INGEST_FAULT_INJECTION_DIR", str(tmp))
    mp.setenv("GOSSY_API_PUBLIC_HOST", "api.rehearsal.invalid")
    mp.setenv("GOSSY_IMAGE_TAG", "latest")
    assert {"API docs disabled", "failure injection disabled", "GOSSY_API_PUBLIC_HOST is a real domain", "image tag pinned (not latest/dev)"} <= failed(prodcheck.run())


def test_production_needs_public_tls_and_acme_contact(prod_env):
    _, mp = prod_env
    mp.setenv("GOSSY_TLS_PROFILE", "internal")
    assert "publicly trusted TLS in production (profile acme)" in failed(prodcheck.run())
    mp.setenv("GOSSY_TLS_PROFILE", "acme")
    mp.setenv("GOSSY_ACME_EMAIL", "")
    assert "ACME contact e-mail set" in failed(prodcheck.run())


def test_staging_allows_test_mode_and_placeholder_domain(prod_env):
    tmp, mp = prod_env
    mp.setenv("GOSSY_ENVIRONMENT", "staging")
    (tmp / "code").write_text("123456")
    mp.setenv("GOSSY_AUTH_TEST_MODE", "true")
    mp.setenv("GOSSY_AUTH_TEST_PHONE_NUMBERS", "+99900000001")
    mp.setenv("GOSSY_AUTH_TEST_OTP_CODE_FILE", str(tmp / "code"))
    mp.setenv("GOSSY_API_PUBLIC_HOST", "api.rehearsal.invalid")
    assert failed(prodcheck.run()) == set()


def test_development_environment_is_not_deployable(prod_env):
    _, mp = prod_env
    mp.setenv("GOSSY_ENVIRONMENT", "development")
    assert "environment is staging or production" in failed(prodcheck.run())
