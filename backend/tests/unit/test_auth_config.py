import pytest
from pydantic import ValidationError

from gossy.config import AuthSettings, CommonSettings, ConfigError, enforce_environment_rules


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    import os

    for key in list(os.environ):
        if key.startswith("GOSSY_AUTH_"):
            monkeypatch.delenv(key)


@pytest.fixture
def keys(tmp_path):
    (tmp_path / "jwt.key").write_text("j" * 64)
    (tmp_path / "otp.key").write_text("o" * 64)
    (tmp_path / "code").write_text("123456")
    return tmp_path


def settings(keys, **kw):
    return AuthSettings(jwt_signing_key_file=keys / "jwt.key", otp_hmac_key_file=keys / "otp.key", **kw)


def test_test_mode_requires_numbers_and_code(keys):
    with pytest.raises(ValidationError):
        settings(keys, test_mode=True, test_otp_code_file=keys / "code")
    with pytest.raises(ValidationError):
        settings(keys, test_mode=True, test_phone_numbers="+99900000001")
    with pytest.raises(ValidationError):
        settings(keys, test_mode=True, test_phone_numbers="12345", test_otp_code_file=keys / "code")
    s = settings(keys, test_mode=True, test_phone_numbers="+99900000001, +99900000002", test_otp_code_file=keys / "code")
    assert s.test_phones() == {"+99900000001", "+99900000002"} and s.test_otp_code() == "123456"


def test_test_numbers_must_be_in_the_unassigned_999_range(keys):
    # A real number with a fixed code would be an account anyone could sign in to.
    with pytest.raises(ValidationError, match=r"\+999"):
        settings(keys, test_mode=True, test_phone_numbers="+99900000001,+919876543210", test_otp_code_file=keys / "code")


def test_test_mode_refused_in_production_allowed_in_staging(keys):
    s = settings(keys, test_mode=True, test_phone_numbers="+99900000001", test_otp_code_file=keys / "code")
    with pytest.raises(ConfigError, match="not allowed in production"):
        enforce_environment_rules(CommonSettings(environment="production"), auth=s)
    enforce_environment_rules(CommonSettings(environment="staging"), auth=s)


def test_development_auth_keys_refused_outside_development(keys):
    (keys / "DEVELOPMENT_ONLY").write_text("dev")
    with pytest.raises(ConfigError, match="development-only"):
        enforce_environment_rules(CommonSettings(environment="staging"), auth=settings(keys))


def test_short_keys_and_bad_codes_rejected(keys):
    (keys / "jwt.key").write_text("short")
    with pytest.raises(ConfigError):
        settings(keys).jwt_signing_key()
    (keys / "code").write_text("12ab56")
    s = settings(keys, test_mode=True, test_phone_numbers="+99900000001", test_otp_code_file=keys / "code")
    with pytest.raises(ConfigError):
        s.test_otp_code()


def test_test_mode_off_by_default(keys):
    assert settings(keys).test_mode is False
