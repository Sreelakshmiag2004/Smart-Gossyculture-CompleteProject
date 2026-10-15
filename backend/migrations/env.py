"""Alembic environment. Runs with the schema-owner role (GOSSY_DB_USER=gossy_owner in dev)."""

from __future__ import annotations

import logging

from alembic import context
from sqlalchemy import create_engine

from gossy.config import CommonSettings, DatabaseSettings, enforce_environment_rules
from gossy.db.engine import database_url
from gossy.logging_setup import configure_logging

common = CommonSettings()
db = DatabaseSettings()
configure_logging(common.log_level, json_output=common.log_json)
enforce_environment_rules(common, secret_files=[db.password_file])
log = logging.getLogger("gossy.migrations")


def run_migrations_online() -> None:
    engine = create_engine(database_url(db), connect_args={"connect_timeout": db.connect_timeout_s})
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=None, transaction_per_migration=True)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
    log.info("migrations_applied", extra={"database": db.name})


if context.is_offline_mode():
    raise SystemExit("offline (SQL script) mode is not supported; run against a database")
run_migrations_online()
