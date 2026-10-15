"""Generate DEVELOPMENT-ONLY secrets into the Compose secrets volume.

    docker compose -f deploy/dev/compose.yaml --profile setup run --rm bootstrap

Creates (idempotently) inside --secrets-dir:
  DEVELOPMENT_ONLY            marker; staging/production refuse secrets from this tree
  db/{postgres,owner,app}.password
  mqtt/{svc-ingest,<device>...}.password   one credential per device (Phase 0 ADR-03)
  certs/ca.{crt,key}          development CA, clearly named NOT FOR PRODUCTION
  certs/broker.{crt,key}      broker certificate (SAN: mosquitto, localhost, 127.0.0.1)
  auth/jwt-signing.key        access-token signing key (random, 64 chars)
  auth/otp-hmac.key           HMAC key for OTP and device claim-code hashes
  auth/test-otp.code          6-digit fixed code for the allow-listed TEST phone numbers

Every password starts with "devonly-" so it cannot be mistaken for a production credential.
These files live only in a Docker volume, never in the repository. File modes are relaxed
(0644) so the different container users (postgres, mosquitto, app) can read them: acceptable
for local development only; production secrets management is a separate decision (U-5).
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import os
import secrets
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

MARKER = "DEVELOPMENT_ONLY"
DB_ROLES = ("postgres", "owner", "app")
# svc-health: used only by the broker healthcheck (TLS + auth + subscribe to one health topic).
SERVICE_ACCOUNTS = ("svc-ingest", "svc-health")
DEFAULT_DEVICES = ("sim-0001", "sim-0002")
BROKER_DNS = ("mosquitto", "localhost")
ORG = "Smart Gossyculture (DEVELOPMENT ONLY)"


def _password() -> str:
    return "devonly-" + secrets.token_urlsafe(24)


def _write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.chmod(tmp, mode)
    tmp.replace(path)


def _key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def _pem_key(key: ec.EllipticCurvePrivateKey) -> bytes:
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())


def _name(cn: str) -> x509.Name:
    return x509.Name([x509.NameAttribute(NameOID.ORGANIZATION_NAME, ORG), x509.NameAttribute(NameOID.COMMON_NAME, cn)])


def make_certificates(days: int) -> dict[str, bytes]:
    now = dt.datetime.now(dt.UTC)
    ca_key = _key()
    ca_name = _name("Smart Gossyculture DEV CA - NOT FOR PRODUCTION")
    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    broker_key = _key()
    broker_cert = (
        x509.CertificateBuilder()
        .subject_name(_name("mosquitto (development)"))
        .issuer_name(ca_name)
        .public_key(broker_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - dt.timedelta(minutes=5))
        .not_valid_after(now + dt.timedelta(days=days))
        .add_extension(
            x509.SubjectAlternativeName([*(x509.DNSName(d) for d in BROKER_DNS), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
        .sign(ca_key, hashes.SHA256())
    )
    pem = serialization.Encoding.PEM
    return {
        "certs/ca.crt": ca_cert.public_bytes(pem),
        "certs/ca.key": _pem_key(ca_key),
        "certs/broker.crt": broker_cert.public_bytes(pem),
        "certs/broker.key": _pem_key(broker_key),
    }


AUTH_KEYS = ("auth/jwt-signing.key", "auth/otp-hmac.key")
TEST_OTP_CODE = "auth/test-otp.code"


def _test_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def expected_files(devices: tuple[str, ...]) -> list[str]:
    return (
        [MARKER]
        + list(AUTH_KEYS)
        + [TEST_OTP_CODE]
        + [f"db/{r}.password" for r in DB_ROLES]
        + [f"mqtt/{u}.password" for u in (*SERVICE_ACCOUNTS, *devices)]
        + ["certs/ca.crt", "certs/ca.key", "certs/broker.crt", "certs/broker.key"]
    )


def bootstrap(secrets_dir: Path, *, devices: tuple[str, ...] = DEFAULT_DEVICES, cert_days: int = 365, force: bool = False) -> list[str]:
    """Create any missing secret. Existing secrets are kept unless ``force``. Returns created paths."""
    for d in devices:
        if not d.startswith("sim-"):
            raise ValueError(f"bootstrap only creates simulator device credentials (sim-*): {d!r}")
    created: list[str] = []

    def missing(rel: str) -> bool:
        return force or not (secrets_dir / rel).exists()

    if missing(MARKER):
        _write(secrets_dir / MARKER, b"Secrets in this directory are for local development only. Never use them elsewhere.\n")
        created.append(MARKER)
    for rel in [f"db/{r}.password" for r in DB_ROLES] + [f"mqtt/{u}.password" for u in (*SERVICE_ACCOUNTS, *devices)]:
        if missing(rel):
            _write(secrets_dir / rel, _password().encode())
            created.append(rel)
    for rel in AUTH_KEYS:
        if missing(rel):
            _write(secrets_dir / rel, ("devonly-" + secrets.token_urlsafe(48)).encode())
            created.append(rel)
    if missing(TEST_OTP_CODE):
        _write(secrets_dir / TEST_OTP_CODE, _test_code().encode())
        created.append(TEST_OTP_CODE)
    if any(missing(rel) for rel in ("certs/ca.crt", "certs/ca.key", "certs/broker.crt", "certs/broker.key")):
        for rel, data in make_certificates(cert_days).items():
            _write(secrets_dir / rel, data, 0o600 if rel == "certs/ca.key" else 0o644)
            created.append(rel)
    return created


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--secrets-dir", type=Path, required=True)
    p.add_argument("--device", action="append", dest="devices", help="simulator device id (repeatable)")
    p.add_argument("--cert-days", type=int, default=365)
    p.add_argument("--force", action="store_true", help="regenerate everything (invalidates existing credentials)")
    args = p.parse_args(argv)
    devices = tuple(args.devices) if args.devices else DEFAULT_DEVICES
    created = bootstrap(args.secrets_dir, devices=devices, cert_days=args.cert_days, force=args.force)
    missing = [f for f in expected_files(devices) if not (args.secrets_dir / f).exists()]
    if missing:
        print(f"bootstrap incomplete, missing: {missing}", file=sys.stderr)
        return 1
    # Names only; secret values are never printed.
    print("created: " + (", ".join(created) if created else "nothing (already initialised)"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
