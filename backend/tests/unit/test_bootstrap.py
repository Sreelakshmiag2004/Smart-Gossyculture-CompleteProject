import pytest
from cryptography import x509

from gossy_devtools.bootstrap import bootstrap, expected_files


def test_bootstrap_creates_all_files_with_devonly_passwords(tmp_path):
    created = bootstrap(tmp_path, cert_days=30)
    for rel in expected_files(("sim-0001", "sim-0002")):
        assert (tmp_path / rel).exists(), rel
    passwords = [p.read_text() for p in tmp_path.rglob("*.password")]
    assert passwords and all(p.startswith("devonly-") and len(p) > 30 for p in passwords)
    assert len(set(passwords)) == len(passwords)  # separate credentials per account/device
    assert "DEVELOPMENT_ONLY" in created


def test_bootstrap_is_idempotent(tmp_path):
    bootstrap(tmp_path, cert_days=30)
    before = (tmp_path / "mqtt" / "sim-0001.password").read_text()
    assert bootstrap(tmp_path, cert_days=30) == []
    assert (tmp_path / "mqtt" / "sim-0001.password").read_text() == before


def test_certificates_are_labelled_development_and_have_broker_sans(tmp_path):
    bootstrap(tmp_path, cert_days=30)
    ca = x509.load_pem_x509_certificate((tmp_path / "certs" / "ca.crt").read_bytes())
    broker = x509.load_pem_x509_certificate((tmp_path / "certs" / "broker.crt").read_bytes())
    assert "NOT FOR PRODUCTION" in ca.subject.rfc4514_string()
    assert broker.issuer == ca.subject
    sans = broker.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert {"mosquitto", "localhost"} <= set(sans.get_values_for_type(x509.DNSName))


def test_bootstrap_refuses_non_simulator_devices(tmp_path):
    with pytest.raises(ValueError):
        bootstrap(tmp_path, devices=("bb-000123",))
