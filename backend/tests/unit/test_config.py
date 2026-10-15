import pytest
from pydantic import ValidationError

from gossy.config import (
    ApiSettings,
    CommonSettings,
    ConfigError,
    DatabaseSettings,
    MqttSettings,
    enforce_environment_rules,
)


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    import os

    for key in list(os.environ):
        if key.startswith("GOSSY_"):
            monkeypatch.delenv(key)


def test_environment_is_required():
    with pytest.raises(ValidationError):
        CommonSettings()


def test_database_requires_exactly_one_password_source(monkeypatch, tmp_path):
    for k, v in {"GOSSY_DB_HOST": "db", "GOSSY_DB_NAME": "gossy", "GOSSY_DB_USER": "app"}.items():
        monkeypatch.setenv(k, v)
    with pytest.raises(ValidationError):
        DatabaseSettings()
    monkeypatch.setenv("GOSSY_DB_PASSWORD", "x")
    monkeypatch.setenv("GOSSY_DB_PASSWORD_FILE", str(tmp_path / "p"))
    with pytest.raises(ValidationError):
        DatabaseSettings()


def test_password_read_from_file_and_not_in_repr(monkeypatch, tmp_path):
    secret = tmp_path / "db.password"
    secret.write_text("s3cr3t-value\n")
    for k, v in {"GOSSY_DB_HOST": "db", "GOSSY_DB_NAME": "gossy", "GOSSY_DB_USER": "app", "GOSSY_DB_PASSWORD_FILE": str(secret)}.items():
        monkeypatch.setenv(k, v)
    s = DatabaseSettings()
    assert s.password_value() == "s3cr3t-value"
    monkeypatch.setenv("GOSSY_DB_PASSWORD", "inline-secret")
    monkeypatch.delenv("GOSSY_DB_PASSWORD_FILE")
    assert "inline-secret" not in repr(DatabaseSettings())


def test_missing_password_file_is_explicit_error(tmp_path):
    s = DatabaseSettings(host="db", name="gossy", user="app", password_file=tmp_path / "missing")
    with pytest.raises(ConfigError, match="cannot read password file"):
        s.password_value()


def test_mqtt_has_no_plaintext_option():
    # TLS is mandatory: there is no switch to disable it or to skip certificate verification.
    assert not any(k in f for f in MqttSettings.model_fields for k in ("insecure", "plain", "tls_enabled", "verify"))
    with pytest.raises(ValidationError):
        MqttSettings(host="m", client_id="c", username="u", password="p")  # ca_file required


def test_telemetry_freshness_defaults_are_the_contract_values(monkeypatch):
    # docs/mqtt-contract.md: one telemetry message every 60 s; not current after 180 s without one.
    api = ApiSettings()
    assert (api.telemetry_interval_s, api.telemetry_stale_after_s) == (60, 180)
    monkeypatch.setenv("GOSSY_API_TELEMETRY_INTERVAL_S", "30")
    monkeypatch.setenv("GOSSY_API_TELEMETRY_STALE_AFTER_S", "90")
    api = ApiSettings()
    assert (api.telemetry_interval_s, api.telemetry_stale_after_s) == (30, 90)


def test_stale_threshold_cannot_be_shorter_than_one_interval():
    with pytest.raises(ValidationError):
        ApiSettings(telemetry_interval_s=60, telemetry_stale_after_s=59)
    for bad in ({"telemetry_interval_s": 0}, {"telemetry_stale_after_s": 0}):
        with pytest.raises(ValidationError):
            ApiSettings(**bad)


@pytest.mark.parametrize("env", ["staging", "production"])
def test_docs_refused_outside_development(env):
    with pytest.raises(ConfigError):
        enforce_environment_rules(CommonSettings(environment=env), api=ApiSettings(docs_enabled=True))


@pytest.mark.parametrize("env", ["staging", "production"])
def test_development_secrets_refused_outside_development(env, tmp_path):
    (tmp_path / "DEVELOPMENT_ONLY").write_text("dev")
    (tmp_path / "db").mkdir()
    secret = tmp_path / "db" / "app.password"
    secret.write_text("devonly-x")
    with pytest.raises(ConfigError, match="development-only"):
        enforce_environment_rules(CommonSettings(environment=env), secret_files=[secret])


def test_development_secrets_allowed_in_development(tmp_path):
    (tmp_path / "DEVELOPMENT_ONLY").write_text("dev")
    secret = tmp_path / "app.password"
    secret.write_text("devonly-x")
    enforce_environment_rules(CommonSettings(environment="development"), secret_files=[secret], api=ApiSettings(docs_enabled=True))
