"""CLI: ``python -m gossy_sim --device-id sim-0001 [--interval 60] [--count 0] [--silent-after 0]``.

Connection settings come from GOSSY_SIM_* environment variables (see .env.dev.example);
the password is read from GOSSY_SIM_PASSWORD_FILE.

Modes: normal (telemetry every ``--interval`` seconds; the contract's 60 s by default),
online but silent (``--silent-after N``), and offline (stop the process: a clean stop publishes
``offline``, a killed process leaves it to the broker's Last Will).
"""

from __future__ import annotations

import argparse
import asyncio
import os
import random
import sys
from pathlib import Path

from gossy.logging_setup import configure_logging
from gossy.mqtt.connection import build_tls_context
from gossy_sim.device import SimulatedDevice
from gossy_sim.publisher import BrokerConfig, run_simulation

# docs/mqtt-contract.md: a device reports telemetry every 60 seconds.
DEFAULT_INTERVAL_S = 60.0


def _env(name: str, default: str | None = None) -> str | None:
    return os.environ.get(f"GOSSY_SIM_{name}", default)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="gossy_sim", description="Development-only BollBot device simulator")
    p.add_argument("--device-id", default=_env("DEVICE_ID"), required=_env("DEVICE_ID") is None)
    p.add_argument("--host", default=_env("HOST", "mosquitto"))
    p.add_argument("--port", type=int, default=int(_env("PORT", "8883")))
    p.add_argument("--ca-file", type=Path, default=_env("CA_FILE"), required=_env("CA_FILE") is None)
    p.add_argument("--password-file", type=Path, default=_env("PASSWORD_FILE"), required=_env("PASSWORD_FILE") is None)
    p.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_S, help="seconds between telemetry ticks (default: the contract's reporting interval, 60 s)")
    p.add_argument("--count", type=int, default=0, help="number of ticks (0 = run until stopped)")
    p.add_argument("--silent-after", type=int, default=0, help="after N ticks stay connected (online) but publish nothing more; 0 = never")
    p.add_argument("--pest-probability", type=float, default=0.1)
    p.add_argument("--harvest-probability", type=float, default=0.3)
    p.add_argument("--duplicate-every", type=int, default=0, help="re-send a previous message every N ticks (idempotency demo)")
    p.add_argument("--seed", type=int, default=None)
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    configure_logging(os.environ.get("GOSSY_LOG_LEVEL", "INFO"))
    rng = random.Random(args.seed)
    device = SimulatedDevice(args.device_id, rng=rng)
    broker = BrokerConfig(
        host=args.host,
        port=args.port,
        username=args.device_id,  # broker username == deviceId (ACL pattern %u)
        password=args.password_file.read_text(encoding="utf-8").strip(),
        tls_context=build_tls_context(args.ca_file),
    )
    try:
        sent = asyncio.run(
            run_simulation(
                device,
                broker,
                interval_s=args.interval,
                count=args.count,
                pest_probability=args.pest_probability,
                harvest_probability=args.harvest_probability,
                duplicate_every=args.duplicate_every,
                rng=rng,
                silent_after=args.silent_after,
            )
        )
    except KeyboardInterrupt:
        return 130
    print(f"simulator finished: {sent} messages published", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
