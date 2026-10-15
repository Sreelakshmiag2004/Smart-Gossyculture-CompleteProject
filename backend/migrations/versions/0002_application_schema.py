"""Application schema: users, farms, device registry, OTP challenges, sessions, refresh tokens,
alerts, audit log; replay cursor + payload on the ingestion ledger.

Revision ID: 0002
Revises: 0001
Create Date: 2026-09-29
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

UUID_PK = dict(primary_key=True, server_default=sa.text("gen_random_uuid()"))
TS = sa.DateTime(timezone=True)


def upgrade() -> None:
    # Ledger: server-side monotonic cursor (existing rows are numbered) and replayable payload.
    op.execute("ALTER TABLE ingested_messages ADD COLUMN ingest_seq BIGINT GENERATED ALWAYS AS IDENTITY")
    op.create_unique_constraint("uq_ingested_messages_ingest_seq", "ingested_messages", ["ingest_seq"])
    op.add_column("ingested_messages", sa.Column("data", postgresql.JSONB))

    op.create_table(
        "users",
        sa.Column("id", sa.Uuid, **UUID_PK),
        sa.Column("phone_e164", sa.String(16), nullable=False, unique=True),
        sa.Column("display_name", sa.String(80)),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("last_login_at", TS),
        sa.CheckConstraint("role IN ('farmer', 'admin')", name="ck_users_role"),
        sa.CheckConstraint("status IN ('active', 'disabled')", name="ck_users_status"),
        sa.CheckConstraint(r"phone_e164 ~ '^\+[1-9][0-9]{7,14}$'", name="ck_users_phone_e164"),
    )

    op.create_table(
        "farms",
        sa.Column("id", sa.Uuid, **UUID_PK),
        sa.Column("owner_user_id", sa.Uuid, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("created_at", TS, nullable=False),
    )
    op.create_index("ix_farms_owner", "farms", ["owner_user_id"])

    op.create_table(
        "devices",
        sa.Column("device_id", sa.String(64), primary_key=True),
        sa.Column("farm_id", sa.Uuid, sa.ForeignKey("farms.id")),
        sa.Column("display_name", sa.String(80)),
        sa.Column("registration_state", sa.String(16), nullable=False),
        sa.Column("claim_code_hash", sa.String(64)),
        sa.Column("claim_code_expires_at", TS),
        sa.Column("registered_at", TS, nullable=False),
        sa.Column("registered_by", sa.Uuid, sa.ForeignKey("users.id")),
        sa.Column("claimed_at", TS),
        sa.Column("claimed_by", sa.Uuid, sa.ForeignKey("users.id")),
        sa.Column("decommissioned_at", TS),
        sa.CheckConstraint("registration_state IN ('provisioned', 'active', 'decommissioned')", name="ck_devices_state"),
        sa.CheckConstraint("registration_state <> 'active' OR farm_id IS NOT NULL", name="ck_devices_active_has_farm"),
    )
    op.create_index("ix_devices_farm", "devices", ["farm_id"])

    op.create_table(
        "otp_challenges",
        sa.Column("id", sa.Uuid, **UUID_PK),
        sa.Column("phone_e164", sa.String(16), nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("attempts", sa.Integer, nullable=False),
        sa.Column("consumed_at", TS),
    )
    op.create_index("ix_otp_challenges_phone_created", "otp_challenges", ["phone_e164", sa.text("created_at DESC")])

    op.create_table(
        "auth_sessions",
        sa.Column("id", sa.Uuid, **UUID_PK),
        sa.Column("user_id", sa.Uuid, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("revoked_at", TS),
        sa.Column("revoke_reason", sa.String(32)),
    )
    op.create_index("ix_auth_sessions_user", "auth_sessions", ["user_id"])

    op.create_table(
        "refresh_tokens",
        sa.Column("token_hash", sa.String(64), primary_key=True),
        sa.Column("session_id", sa.Uuid, sa.ForeignKey("auth_sessions.id"), nullable=False),
        sa.Column("issued_at", TS, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("used_at", TS),
    )
    op.create_index("ix_refresh_tokens_session", "refresh_tokens", ["session_id"])

    op.create_table(
        "alerts",
        sa.Column("id", sa.Uuid, **UUID_PK),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("alert_type", sa.String(32), nullable=False),
        sa.Column("severity", sa.String(16), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("source_msg_id", sa.String(26), nullable=False),
        sa.Column("occurred_at", TS, nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("details", postgresql.JSONB, nullable=False),
        sa.Column("acknowledged_at", TS),
        sa.Column("acknowledged_by", sa.Uuid, sa.ForeignKey("users.id")),
        sa.UniqueConstraint("source_msg_id", "alert_type", name="uq_alerts_source_type"),
        sa.CheckConstraint("status IN ('open', 'acknowledged')", name="ck_alerts_status"),
        sa.CheckConstraint("severity IN ('info', 'warning')", name="ck_alerts_severity"),
    )
    op.create_index("ix_alerts_device_occurred", "alerts", ["device_id", sa.text("occurred_at DESC")])
    op.create_index("ix_alerts_status", "alerts", ["status"])

    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger, sa.Identity(always=True), primary_key=True),
        sa.Column("ts", TS, nullable=False),
        sa.Column("actor_user_id", sa.Uuid),
        sa.Column("action", sa.String(64), nullable=False),
        sa.Column("outcome", sa.String(16), nullable=False),
        sa.Column("target", sa.String(128)),
        sa.Column("request_id", sa.String(64)),
        sa.Column("client_ip", sa.String(64)),
        sa.Column("details", postgresql.JSONB, nullable=False),
        sa.CheckConstraint("outcome IN ('success', 'failure', 'denied')", name="ck_audit_outcome"),
    )
    op.create_index("ix_audit_log_ts", "audit_log", [sa.text("ts DESC")])
    # Append-only, independent of role names: the runtime role gets UPDATE on all tables through
    # default privileges, so a trigger (which the runtime role cannot drop: no DDL) forbids it here.
    op.execute(
        """
        CREATE FUNCTION audit_log_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            RAISE EXCEPTION 'audit_log is append-only';
        END $$;
        CREATE TRIGGER trg_audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
            FOR EACH ROW EXECUTE FUNCTION audit_log_append_only();
        """
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER trg_audit_log_append_only ON audit_log")
    op.execute("DROP FUNCTION audit_log_append_only()")
    for table in ("audit_log", "alerts", "refresh_tokens", "auth_sessions", "otp_challenges", "devices", "farms", "users"):
        op.drop_table(table)
    op.drop_column("ingested_messages", "data")
    op.drop_constraint("uq_ingested_messages_ingest_seq", "ingested_messages")
    op.drop_column("ingested_messages", "ingest_seq")
