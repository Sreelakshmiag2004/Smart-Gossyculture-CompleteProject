"""Configuration from environment variables.

Rules (Phase 1):
* No credentials in code. Secrets come from ``*_PASSWORD`` or, preferably, ``*_PASSWORD_FILE``.
* ``GOSSY_ENVIRONMENT`` has no default: every process must state where it runs.
* Development secrets are generated next to a ``DEVELOPMENT_ONLY`` marker file. Staging and
  production refuse to start if any secret file comes from such a directory.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["development", "test", "staging", "production"]
LogLevel = Literal["DEBUG", "INFO", "WARNING", "ERROR"]
DEV_MARKER_FILENAME = "DEVELOPMENT_ONLY"
_PROTECTED_ENVIRONMENTS = {"staging", "production"}


class ConfigError(RuntimeError):
    """Raised when configuration is unsafe or incomplete for the selected environment."""


class _Secret(BaseSettings):
    """Mixin: exactly one of ``password`` / ``password_file`` must be provided."""

    password: SecretStr | None = None
    password_file: Path | None = None

    @model_validator(mode="after")
    def _one_password_source(self):
        if (self.password is None) == (self.password_file is None):
            raise ValueError("set exactly one of PASSWORD or PASSWORD_FILE")
        return self

    def password_value(self) -> str:
        if self.password is not None:
            return self.password.get_secret_value()
        assert self.password_file is not None
        try:
            value = self.password_file.read_text(encoding="utf-8").strip()
        except OSError as exc:
            raise ConfigError(f"cannot read password file {self.password_file}: {exc.strerror}") from exc
        if not value:
            raise ConfigError(f"password file {self.password_file} is empty")
        return value


class CommonSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GOSSY_", extra="ignore")

    environment: Environment
    log_level: LogLevel = "INFO"
    log_json: bool = True


class DatabaseSettings(_Secret):
    model_config = SettingsConfigDict(env_prefix="GOSSY_DB_", extra="ignore")

    host: str
    port: int = Field(default=5432, ge=1, le=65535)
    name: str
    user: str
    connect_timeout_s: int = Field(default=5, ge=1, le=60)
    pool_size: int = Field(default=5, ge=1, le=50)


class MqttSettings(_Secret):
    model_config = SettingsConfigDict(env_prefix="GOSSY_MQTT_", extra="ignore")

    host: str
    port: int = Field(default=8883, ge=1, le=65535)
    client_id: str = Field(min_length=1, max_length=64)
    username: str = Field(min_length=1, max_length=64)
    # TLS is mandatory (Phase 0 ADR-03): there is no plaintext option.
    ca_file: Path
    keepalive_s: int = Field(default=30, ge=5, le=600)
    session_expiry_s: int = Field(default=3600, ge=0, le=7 * 24 * 3600)
    reconnect_min_s: float = Field(default=1.0, gt=0, le=60)
    reconnect_max_s: float = Field(default=30.0, gt=0, le=600)


class IngestSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GOSSY_INGEST_", extra="ignore")

    max_payload_bytes: int = Field(default=65536, ge=1024, le=1_048_576)
    max_future_skew_s: int = Field(default=300, ge=0, le=86_400)
    # Transient database errors (connection lost, database down, deadlock) are retried WITHOUT
    # limit: the MQTT message stays unacknowledged and the broker keeps it. Only errors that are
    # not transient count towards store_retry_attempts, after which the message is dead-lettered.
    store_retry_attempts: int = Field(default=5, ge=1, le=20)
    store_retry_backoff_s: float = Field(default=0.5, gt=0, le=30)
    store_retry_max_backoff_s: float = Field(default=30.0, gt=0, le=600)
    # Monitoring (Phase 3): transient retrying for at least this long is reported as a
    # "prolonged" blockage instead of a temporary retry.
    retry_prolonged_after_s: float = Field(default=300.0, gt=0, le=86_400)
    # Development/test failure injection (hard process exit at a named point). Refused in
    # staging/production. See gossy.ingest.faults.
    fault_injection_dir: Path | None = None


class ApiSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="GOSSY_API_", extra="ignore")

    docs_enabled: bool = False
    max_request_body_bytes: int = Field(default=65536, ge=1024, le=10_485_760)
    # Device claim codes (recommended default; no value is given by the requirements).
    claim_code_ttl_s: int = Field(default=7 * 24 * 3600, ge=60, le=90 * 24 * 3600)
    # Claim attempts per user per 10 minutes (in-process limiter; guards claim-code guessing).
    claim_attempts_per_user: int = Field(default=10, ge=1, le=10_000)
    # WebSocket session behaviour.
    ws_heartbeat_s: float = Field(default=25.0, gt=0, le=300)
    ws_refresh_s: float = Field(default=30.0, gt=0, le=600)
    ws_queue_size: int = Field(default=1000, ge=10, le=100_000)
    ws_replay_limit: int = Field(default=1000, ge=1, le=100_000)
    # Telemetry freshness (Phase 5A, docs/mqtt-contract.md): the contract's reporting interval
    # and the time without telemetry after which a reading is no longer "current". Both are
    # given to the app with every device so that the app hard-codes neither.
    telemetry_interval_s: int = Field(default=60, ge=1, le=3600)
    telemetry_stale_after_s: int = Field(default=180, ge=1, le=86_400)

    @model_validator(mode="after")
    def _stale_not_before_one_interval(self) -> ApiSettings:
        if self.telemetry_stale_after_s < self.telemetry_interval_s:
            raise ValueError("GOSSY_API_TELEMETRY_STALE_AFTER_S must not be smaller than GOSSY_API_TELEMETRY_INTERVAL_S")
        return self


E164_PATTERN = r"^\+[1-9][0-9]{7,14}$"
_E164_RE = re.compile(E164_PATTERN)
TEST_PHONE_PREFIX = "+999"
MIN_KEY_BYTES = 32


class AuthSettings(BaseSettings):
    """Phone-OTP authentication.

    ``test_mode`` is the ONLY OTP delivery mechanism implemented (Phase 2): allow-listed test
    numbers accept a fixed code read from a secret file; no message is sent anywhere. It is
    refused in production. Real SMS delivery is unresolved (U-4) and not implemented.
    """

    model_config = SettingsConfigDict(env_prefix="GOSSY_AUTH_", extra="ignore")

    jwt_signing_key_file: Path
    otp_hmac_key_file: Path
    issuer: str = "gossy-api"
    audience: str = "gossy-app"
    access_token_ttl_s: int = Field(default=900, ge=1, le=3600)
    refresh_token_ttl_s: int = Field(default=30 * 24 * 3600, ge=60, le=90 * 24 * 3600)
    otp_ttl_s: int = Field(default=300, ge=30, le=900)
    otp_max_attempts: int = Field(default=5, ge=1, le=10)
    # In-process sliding-window limits (per API process; see known limitations).
    rate_window_s: int = Field(default=600, ge=1, le=86_400)
    otp_requests_per_phone: int = Field(default=3, ge=1, le=10_000)
    otp_requests_per_ip: int = Field(default=10, ge=1, le=10_000)
    otp_verifications_per_ip: int = Field(default=20, ge=1, le=10_000)
    test_mode: bool = False
    # Comma-separated E.164 numbers. Development uses the unassigned +999 range only.
    test_phone_numbers: str = ""
    test_otp_code_file: Path | None = None

    @model_validator(mode="after")
    def _test_mode_complete(self):
        if self.test_mode:
            if not self.test_phones():
                raise ValueError("test_mode requires TEST_PHONE_NUMBERS")
            if self.test_otp_code_file is None:
                raise ValueError("test_mode requires TEST_OTP_CODE_FILE")
        return self

    def test_phones(self) -> frozenset[str]:
        phones = frozenset(p.strip() for p in self.test_phone_numbers.split(",") if p.strip())
        bad = [p for p in phones if not _E164_RE.match(p)]
        if bad:
            raise ValueError(f"test phone numbers must be E.164: {bad}")
        # A real subscriber number with a fixed code would be an account that anyone can sign in
        # to, so test numbers are restricted to the unassigned +999 country code.
        real = [p for p in phones if not p.startswith(TEST_PHONE_PREFIX)]
        if real:
            raise ValueError(f"test phone numbers must use the unassigned {TEST_PHONE_PREFIX} range: {real}")
        return phones

    def test_otp_code(self) -> str:
        assert self.test_otp_code_file is not None
        code = _read_secret_file(self.test_otp_code_file).decode().strip()
        if not re.fullmatch(r"[0-9]{6}", code):
            raise ConfigError("test OTP code file must contain exactly 6 digits")
        return code

    def jwt_signing_key(self) -> bytes:
        return _read_key(self.jwt_signing_key_file)

    def otp_hmac_key(self) -> bytes:
        return _read_key(self.otp_hmac_key_file)


def _read_secret_file(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise ConfigError(f"cannot read secret file {path}: {exc.strerror}") from exc


def _read_key(path: Path) -> bytes:
    key = _read_secret_file(path).strip()
    if len(key) < MIN_KEY_BYTES:
        raise ConfigError(f"key file {path} is shorter than {MIN_KEY_BYTES} bytes")
    return key


def _is_development_secret(path: Path) -> bool:
    resolved = path.resolve()
    return any((parent / DEV_MARKER_FILENAME).exists() for parent in resolved.parents)


def enforce_environment_rules(
    common: CommonSettings,
    *,
    secret_files: list[Path | None] = (),
    api: ApiSettings | None = None,
    auth: AuthSettings | None = None,
    ingest: IngestSettings | None = None,
) -> None:
    """Refuse unsafe combinations before the process starts serving."""
    if ingest is not None and ingest.fault_injection_dir is not None and common.environment not in ("development", "test"):
        raise ConfigError(f"ingest failure injection is only allowed in development/test, not {common.environment}")
    if auth is not None:
        if auth.test_mode and common.environment == "production":
            raise ConfigError("OTP test mode (fixed test codes) is not allowed in production")
        secret_files = [*secret_files, auth.jwt_signing_key_file, auth.otp_hmac_key_file, auth.test_otp_code_file]
    if common.environment not in _PROTECTED_ENVIRONMENTS:
        return
    if api is not None and api.docs_enabled:
        raise ConfigError(f"API docs must be disabled in {common.environment}")
    for path in secret_files:
        if path is not None and _is_development_secret(path):
            raise ConfigError(
                f"secret file {path} is a development-only secret and cannot be used in {common.environment}"
            )
