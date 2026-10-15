"""Operator CLI. The ONLY way to grant the admin role (there is no API for it).

    python -m gossy.manage set-role --phone +99900000009 --role admin

Uses the regular database settings (GOSSY_DB_*). Every change is written to the audit log.
"""

from __future__ import annotations

import argparse
import asyncio
import re
import sys
from datetime import UTC, datetime

from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from gossy.audit import audit
from gossy.config import E164_PATTERN, CommonSettings, DatabaseSettings, enforce_environment_rules
from gossy.db.engine import create_engine
from gossy.db.tables import users
from gossy.logging_setup import configure_logging


async def set_role(phone: str, role: str) -> str:
    db = DatabaseSettings()
    engine = create_engine(db)
    try:
        async with engine.begin() as conn:
            await conn.execute(
                pg_insert(users).values(phone_e164=phone, role=role, status="active", created_at=datetime.now(UTC)).on_conflict_do_nothing(index_elements=["phone_e164"])
            )
            await conn.execute(update(users).where(users.c.phone_e164 == phone).values(role=role))
            user_id = (await conn.execute(select(users.c.id).where(users.c.phone_e164 == phone))).scalar_one()
        await audit(engine, "user.set_role", "success", target=str(user_id), details={"role": role, "via": "cli"})
        return str(user_id)
    finally:
        await engine.dispose()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="gossy.manage")
    sub = p.add_subparsers(dest="command", required=True)
    sr = sub.add_parser("set-role", help="create the user if needed and set its role")
    sr.add_argument("--phone", required=True)
    sr.add_argument("--role", required=True, choices=["farmer", "admin"])
    args = p.parse_args(argv)
    common = CommonSettings()
    configure_logging(common.log_level, json_output=common.log_json)
    enforce_environment_rules(common, secret_files=[DatabaseSettings().password_file])
    if not re.fullmatch(E164_PATTERN, args.phone):
        print("phone must be E.164, e.g. +99900000009", file=sys.stderr)
        return 2
    user_id = asyncio.run(set_role(args.phone, args.role))
    print(f"user {user_id} role={args.role}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
