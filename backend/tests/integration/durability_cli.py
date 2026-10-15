"""Helper for scripts/durability_check.sh (runs inside the dev ``tests`` container).

    python -m tests.integration.durability_cli publish <telemetry-count> [--interval S]
        -> prints a JSON list of {"msgId", "kind"}; also sends one pest and one spray event
    python -m tests.integration.durability_cli verify '<json from publish>' [--timeout S]
        -> waits for every message, prints the effect counts and PASS/FAIL (exit code 0/1)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys

from gossy.config import DatabaseSettings
from gossy.contracts.topics import MessageKind
from gossy.db.engine import create_engine
from gossy_sim.device import OutgoingMessage, SimulatedDevice
from tests.integration.conftest import TEST_DEVICE, publish_as_test_device
from tests.integration.test_durability import effects, expected


async def publish(count: int, interval: float) -> None:
    device = SimulatedDevice(TEST_DEVICE)
    pest = device.pest()
    messages = [pest, device.spray(related_msg_id=pest.msg_id), *(device.telemetry() for _ in range(count))]
    if interval <= 0:
        await publish_as_test_device(messages)
    else:
        for m in messages:
            await publish_as_test_device([m])
            await asyncio.sleep(interval)
    print(json.dumps([{"msgId": m.msg_id, "kind": m.kind.value} for m in messages]))


async def verify(spec: str, timeout: float) -> int:
    items = json.loads(spec)
    messages = [OutgoingMessage("", b"", i["msgId"], MessageKind(i["kind"])) for i in items]
    ids = [m.msg_id for m in messages]
    want = expected(messages)
    engine = create_engine(DatabaseSettings())
    try:
        deadline = asyncio.get_running_loop().time() + timeout
        got = await effects(engine, ids)
        while got["ledger"] != want["ledger"] and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(1)
            got = await effects(engine, ids)
        await asyncio.sleep(2)
        got = await effects(engine, ids)
    finally:
        await engine.dispose()
    summary = {name: {"rows": sum(got[name].values()), "expected": sum(want[name].values()), "max_per_msg": max(got[name].values(), default=0)} for name in want}
    ok = got == want
    print(json.dumps({"result": "PASS" if ok else "FAIL", "messages": len(ids), "missing": sorted(set(ids) - set(got["ledger"])), "effects": summary}))
    return 0 if ok else 1


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    pub = sub.add_parser("publish")
    pub.add_argument("count", type=int)
    pub.add_argument("--interval", type=float, default=0)
    ver = sub.add_parser("verify")
    ver.add_argument("spec")
    ver.add_argument("--timeout", type=float, default=120)
    args = p.parse_args()
    if args.cmd == "publish":
        asyncio.run(publish(args.count, args.interval))
        return 0
    return asyncio.run(verify(args.spec, args.timeout))


if __name__ == "__main__":
    sys.exit(main())
