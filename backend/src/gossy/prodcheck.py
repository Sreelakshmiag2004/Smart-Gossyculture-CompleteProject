"""Production/staging configuration validation. Run on the host before every deployment:

    docker compose run --rm --no-deps api python -m gossy.prodcheck

Loads every service's settings exactly as the services do, applies the same startup rules
(``enforce_environment_rules``) and adds deployment checks that only make sense outside
development. Prints one line per check and exits non-zero if any check fails. Never prints
secret values.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable
from pathlib import Path

from gossy.config import (
    DEV_MARKER_FILENAME, ApiSettings, AuthSettings, CommonSettings, ConfigError, DatabaseSettings, IngestSettings, MqttSettings,
    enforce_environment_rules,
)

DEV_CA_MARKERS = ("NOT FOR PRODUCTION", "DEVELOPMENT ONLY")
PLACEHOLDER_MARKERS = ("example", "changeme", "placeholder", "todo", ".invalid")
Check = tuple[str, bool, str]


def _secret_value_ok(path: Path | None) -> tuple[bool, str]:
    if path is None:
        return False, "not configured"
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return False, f"unreadable ({exc.strerror})"
    if value.startswith("devonly-"):
        return False, "development secret"
    if len(value) < 24:
        return False, "shorter than 24 characters"
    return True, "ok"


def _not_dev_ca(path: Path) -> tuple[bool, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return False, f"unreadable ({exc.strerror})"
    if any(m in text for m in DEV_CA_MARKERS):
        return False, "development CA"
    return True, "ok"


def run(env: dict[str, str] | None = None) -> list[Check]:
    env = dict(os.environ if env is None else env)
    checks: list[Check] = []

    def check(name: str, fn: Callable[[], tuple[bool, str]]) -> None:
        try:
            ok, detail = fn()
        except (ConfigError, ValueError) as exc:
            ok, detail = False, str(exc).splitlines()[0]
        checks.append((name, ok, detail))

    common = CommonSettings()
    checks.append(("environment is staging or production", common.environment in ("staging", "production"), common.environment))
    production = common.environment == "production"

    settings: dict[str, object] = {}
    for key, cls in (("api", ApiSettings), ("auth", AuthSettings), ("db", DatabaseSettings), ("mqtt", MqttSettings), ("ingest", IngestSettings)):
        def load(cls=cls, key=key):
            settings[key] = cls()
            return True, "loaded"
        check(f"{key} settings load", load)
    if len(settings) < 5:
        return checks

    api, auth, db, mqtt, ingest = (settings[k] for k in ("api", "auth", "db", "mqtt", "ingest"))

    def startup_rules():
        enforce_environment_rules(common, secret_files=[db.password_file, mqtt.password_file], api=api, auth=auth, ingest=ingest)
        return True, "api/auth/db/mqtt/ingest rules pass"

    check("service startup rules", startup_rules)
    check("API docs disabled", lambda: (not api.docs_enabled, "disabled" if not api.docs_enabled else "enabled"))
    check("OTP test mode off in production", lambda: (not (production and auth.test_mode), "test mode " + ("ON" if auth.test_mode else "off")))
    check("failure injection disabled", lambda: (ingest.fault_injection_dir is None, "disabled" if ingest.fault_injection_dir is None else "enabled"))
    check("JWT signing key", lambda: _secret_value_ok(auth.jwt_signing_key_file))
    check("OTP/claim HMAC key", lambda: _secret_value_ok(auth.otp_hmac_key_file))
    check("database password", lambda: _secret_value_ok(db.password_file))
    check("MQTT ingest password", lambda: _secret_value_ok(mqtt.password_file))
    check("MQTT CA is not the development CA", lambda: _not_dev_ca(mqtt.ca_file))
    check("no development-secret marker next to secrets", lambda: (
        not any((p.parent / DEV_MARKER_FILENAME).exists() or (p.parent.parent / DEV_MARKER_FILENAME).exists() for p in (db.password_file, mqtt.password_file) if p),
        "none",
    ))
    for var in ("GOSSY_API_PUBLIC_HOST", "GOSSY_MQTT_PUBLIC_HOST"):
        value = env.get(var, "")
        placeholder = not value or any(m in value.lower() for m in PLACEHOLDER_MARKERS)
        checks.append((f"{var} is a real domain", not (production and placeholder), value or "unset"))
    tls_profile = env.get("GOSSY_TLS_PROFILE", "acme")
    checks.append(("publicly trusted TLS in production (profile acme)", not (production and tls_profile != "acme"), tls_profile))
    acme_email = env.get("GOSSY_ACME_EMAIL", "")
    checks.append(("ACME contact e-mail set", not (tls_profile == "acme" and "@" not in acme_email), acme_email or "unset"))
    tag = env.get("GOSSY_IMAGE_TAG", "")
    checks.append(("image tag pinned (not latest/dev)", bool(tag) and tag not in ("latest", "dev"), tag or "unset"))
    return checks


def main() -> int:
    checks = run()
    for name, ok, detail in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")
    failed = [c for c in checks if not c[1]]
    print(f"prodcheck: {len(checks) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
