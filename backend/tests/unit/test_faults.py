"""Failure injection: dev/test only, fires once, never touches the database."""

import pytest

from gossy.config import CommonSettings, ConfigError, IngestSettings, enforce_environment_rules
from gossy.ingest import faults as faults_module
from gossy.ingest.faults import AFTER_COMMIT, BEFORE_TRANSACTION, EXIT_CODE, FaultInjector


class Exited(Exception):
    pass


@pytest.fixture
def exits(monkeypatch):
    codes = []

    def fake_exit(code):
        codes.append(code)
        raise Exited

    monkeypatch.setattr(faults_module.os, "_exit", fake_exit)
    return codes


def test_disabled_injector_does_nothing(tmp_path, exits):
    (tmp_path / "MSG1").write_text(BEFORE_TRANSACTION)
    FaultInjector(None).check(BEFORE_TRANSACTION, "MSG1")
    assert exits == []


def test_armed_fault_fires_once_at_its_point_only(tmp_path, exits):
    injector = FaultInjector(tmp_path)
    (tmp_path / "MSG1").write_text(AFTER_COMMIT)
    injector.check(BEFORE_TRANSACTION, "MSG1")  # other point: no effect
    injector.check(AFTER_COMMIT, "MSG2")  # other message: no effect
    with pytest.raises(Exited):
        injector.check(AFTER_COMMIT, "MSG1")
    assert exits == [EXIT_CODE] and (tmp_path / "MSG1.fired").exists()
    injector.check(AFTER_COMMIT, "MSG1")  # redelivery after the crash: no second crash
    assert exits == [EXIT_CODE]


@pytest.mark.parametrize("environment", ["staging", "production"])
def test_fault_injection_refused_outside_development(tmp_path, environment):
    with pytest.raises(ConfigError, match="failure injection"):
        enforce_environment_rules(CommonSettings(environment=environment), ingest=IngestSettings(fault_injection_dir=tmp_path))


@pytest.mark.parametrize("environment", ["development", "test"])
def test_fault_injection_allowed_in_development(tmp_path, environment):
    enforce_environment_rules(CommonSettings(environment=environment), ingest=IngestSettings(fault_injection_dir=tmp_path))
