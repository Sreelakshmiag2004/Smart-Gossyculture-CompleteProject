from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

log = logging.getLogger("gossy.health")
CHECK_TIMEOUT_S = 3.0


@dataclass(frozen=True)
class CheckResult:
    name: str
    ok: bool
    detail: str | None = None


ReadinessCheck = Callable[[], Awaitable[CheckResult]]


async def run_checks(checks: list[ReadinessCheck]) -> list[CheckResult]:
    return list(await asyncio.gather(*(_guarded(c) for c in checks)))


async def _guarded(check: ReadinessCheck) -> CheckResult:
    name = getattr(check, "check_name", getattr(check, "__name__", "check"))
    try:
        return await asyncio.wait_for(check(), timeout=CHECK_TIMEOUT_S)
    except TimeoutError:
        log.warning("readiness_check_timeout", extra={"check": name})
        return CheckResult(name, False, "timeout")
    except Exception as exc:  # a failing check must never crash the probe
        log.warning("readiness_check_failed", extra={"check": name, "error_type": type(exc).__name__, "error": str(exc)})
        return CheckResult(name, False, type(exc).__name__)


def named(name: str, fn: ReadinessCheck) -> ReadinessCheck:
    fn.check_name = name  # type: ignore[attr-defined]
    return fn


def database_check(engine: AsyncEngine) -> ReadinessCheck:
    async def check() -> CheckResult:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return CheckResult("database", True)

    return named("database", check)


def timescaledb_check(engine: AsyncEngine) -> ReadinessCheck:
    async def check() -> CheckResult:
        async with engine.connect() as conn:
            version = (await conn.execute(text("SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'"))).scalar()
        return CheckResult("timescaledb", version is not None, version or "extension not installed")

    return named("timescaledb", check)


def migrations_check(engine: AsyncEngine, expected_head: str) -> ReadinessCheck:
    async def check() -> CheckResult:
        async with engine.connect() as conn:
            current = (await conn.execute(text("SELECT version_num FROM alembic_version"))).scalar()
        ok = current == expected_head
        return CheckResult("migrations", ok, f"current={current} expected={expected_head}")

    return named("migrations", check)
