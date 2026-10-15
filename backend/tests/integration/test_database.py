import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from gossy.db.migrations import expected_head

pytestmark = pytest.mark.integration


async def scalar(engine, sql):
    async with engine.connect() as conn:
        return (await conn.execute(text(sql))).scalar()


async def test_database_connectivity(engine):
    assert await scalar(engine, "SELECT 1") == 1


async def test_connected_as_least_privilege_app_role(engine):
    assert await scalar(engine, "SELECT current_user") == "gossy_app"


async def test_timescaledb_extension_available(engine):
    version = await scalar(engine, "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'")
    assert version is not None and version.startswith("2.")


async def test_telemetry_and_events_are_hypertables(engine):
    async with engine.connect() as conn:
        names = set((await conn.execute(text("SELECT hypertable_name FROM timescaledb_information.hypertables"))).scalars())
    assert {"telemetry", "device_events"} <= names


async def test_schema_is_at_expected_migration_head(engine):
    assert await scalar(engine, "SELECT version_num FROM alembic_version") == expected_head()


@pytest.mark.parametrize(
    "sql",
    [
        "CREATE TABLE should_not_exist (id int)",
        "DROP TABLE rejected_messages",
        "DELETE FROM ingested_messages",
        "CREATE EXTENSION IF NOT EXISTS pgcrypto",
        # Phase 2 tables
        "DELETE FROM users",
        "DELETE FROM alerts",
        "DELETE FROM refresh_tokens",
        "DROP TRIGGER trg_audit_log_append_only ON audit_log",
        "ALTER TABLE devices DROP CONSTRAINT ck_devices_state",
    ],
)
async def test_app_role_cannot_run_ddl_or_delete(engine, sql):
    with pytest.raises(DBAPIError) as exc:
        async with engine.begin() as conn:
            await conn.execute(text(sql))
    assert "permission denied" in str(exc.value).lower() or "must be owner" in str(exc.value).lower()


async def test_phase2_application_tables_exist(engine):
    async with engine.connect() as conn:
        names = set((await conn.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))).scalars())
    assert {"users", "farms", "devices", "otp_challenges", "auth_sessions", "refresh_tokens", "alerts", "audit_log"} <= names


@pytest.mark.parametrize("sql", ["UPDATE audit_log SET action = 'tampered'", "DELETE FROM audit_log"])
async def test_audit_log_is_append_only(engine, sql):
    async with engine.begin() as conn:
        await conn.execute(text("INSERT INTO audit_log (ts, action, outcome, details) VALUES (now(), 'itest.append_only', 'success', '{}')"))
    with pytest.raises(DBAPIError) as exc:
        async with engine.begin() as conn:
            await conn.execute(text(sql))
    assert "append-only" in str(exc.value) or "permission denied" in str(exc.value).lower()


async def test_secrets_are_stored_only_as_hashes(engine):
    # OTP codes, refresh tokens and claim codes are stored as 64-hex SHA-256/HMAC digests.
    async with engine.connect() as conn:
        for table, column in (("otp_challenges", "code_hash"), ("refresh_tokens", "token_hash"), ("devices", "claim_code_hash")):
            bad = (await conn.execute(text(f"SELECT count(*) FROM {table} WHERE {column} IS NOT NULL AND {column} !~ '^[0-9a-f]{{64}}$'"))).scalar()
            assert bad == 0, table


async def test_ingest_cursor_is_unique_and_monotonic(engine):
    async with engine.connect() as conn:
        dupes = (await conn.execute(text("SELECT count(*) - count(DISTINCT ingest_seq) FROM ingested_messages"))).scalar()
    assert dupes == 0
