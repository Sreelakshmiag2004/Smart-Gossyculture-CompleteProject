"""The broker ACLs must let a device publish every message kind in the contract, and nothing else.

A kind missing from the ACL is not an error the device can see clearly: Mosquitto answers the
publish with a "not authorized" PUBACK and drops the message. This test catches that drift.
"""
from pathlib import Path

import pytest

from gossy.contracts.topics import MessageKind

DEPLOY = Path(__file__).resolve().parents[2] / "deploy"


@pytest.mark.parametrize("env", ["dev", "prod"])
def test_device_write_patterns_cover_exactly_the_contract(env: str) -> None:
    lines = (DEPLOY / env / "mosquitto" / "acl").read_text(encoding="utf-8").splitlines()
    prefix = "pattern write bollbot/v1/%u/"
    granted = {ln.strip()[len(prefix):] for ln in lines if ln.strip().startswith(prefix)}
    assert granted == {k.value for k in MessageKind}
    assert not any(ln.strip().startswith(("pattern read", "pattern readwrite")) for ln in lines)
