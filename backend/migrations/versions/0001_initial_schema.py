"""Initial ingestion schema: idempotency ledger, telemetry/event hypertables, device status, rejections.

Revision ID: 0001
Revises:
Create Date: 2026-09-29

The timescaledb extension is created by the database administrator (dev: deploy/dev/postgres/
10-init-roles.sh), not here, because CREATE EXTENSION timescaledb needs superuser rights that
the migration role deliberately does not have. This migration fails fast if it is missing.
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
                RAISE EXCEPTION 'timescaledb extension is not installed in this database';
            END IF;
        END $$;
        """
    )

    op.create_table(
        "ingested_messages",
        sa.Column("msg_id", sa.String(26), primary_key=True),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("schema_id", sa.String(64), nullable=False),
        sa.Column("seq", sa.BigInteger, nullable=False),
        sa.Column("device_ts", sa.DateTime(timezone=True), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_ingested_messages_device_received", "ingested_messages", ["device_id", sa.text("received_at DESC")])

    op.create_table(
        "telemetry",
        sa.Column("time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("msg_id", sa.String(26), nullable=False),
        sa.Column("battery_pct", sa.Float, nullable=False),
        sa.Column("moisture_rh_pct", sa.Float),
        sa.Column("air_temp_c", sa.Float),
        sa.Column("bolls_harvested_total", sa.BigInteger),
        sa.Column("solar_active", sa.Boolean),
    )
    op.execute("SELECT create_hypertable('telemetry', by_range('time'))")
    op.create_index("ix_telemetry_device_time", "telemetry", ["device_id", sa.text("time DESC")])

    op.create_table(
        "device_events",
        sa.Column("time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(64), nullable=False),
        sa.Column("msg_id", sa.String(26), nullable=False),
        sa.Column("event_type", sa.String(32), nullable=False),
        sa.Column("data", postgresql.JSONB, nullable=False),
    )
    op.execute("SELECT create_hypertable('device_events', by_range('time'))")
    op.create_index("ix_device_events_device_time", "device_events", ["device_id", sa.text("time DESC")])
    op.create_index("ix_device_events_type_time", "device_events", ["event_type", sa.text("time DESC")])

    op.create_table(
        "device_status",
        sa.Column("device_id", sa.String(64), primary_key=True),
        sa.Column("state", sa.String(16)),
        sa.Column("state_at", sa.DateTime(timezone=True)),
        sa.Column("last_seen_at", sa.DateTime(timezone=True)),
        sa.Column("last_msg_id", sa.String(26)),
    )

    op.create_table(
        "rejected_messages",
        sa.Column("id", sa.BigInteger, sa.Identity(always=True), primary_key=True),
        sa.Column("received_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("topic", sa.String(256), nullable=False),
        sa.Column("reason", sa.String(64), nullable=False),
        sa.Column("detail", sa.String(512)),
        sa.Column("payload_size", sa.Integer, nullable=False),
        sa.Column("payload_excerpt", sa.Text),
    )
    op.create_index("ix_rejected_messages_received", "rejected_messages", [sa.text("received_at DESC")])


def downgrade() -> None:
    for table in ("rejected_messages", "device_status", "device_events", "telemetry", "ingested_messages"):
        op.drop_table(table)
