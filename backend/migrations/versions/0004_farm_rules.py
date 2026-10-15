"""Farm rules (Phase II, Module 7b): farm location, operators, trap counts, scouting
observations, detection confirmations, advisories, farm status and the forecast cache.

The runtime role has no DELETE privilege, so removal is a timestamp (removed_at / deleted_at).

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-15
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

UUID_PK = dict(primary_key=True, server_default=sa.text("gen_random_uuid()"))
TS = sa.DateTime(timezone=True)


def _farm_fk() -> sa.Column:
    return sa.Column("farm_id", sa.Uuid, sa.ForeignKey("farms.id"), nullable=False)


def _recorded() -> list[sa.Column]:
    return [
        sa.Column("recorded_by", sa.Uuid, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("recorded_at", TS, nullable=False),
        sa.Column("deleted_at", TS),
    ]


def upgrade() -> None:
    op.add_column("farms", sa.Column("latitude", sa.Float))
    op.add_column("farms", sa.Column("longitude", sa.Float))
    op.create_check_constraint("ck_farms_latitude", "farms", "latitude IS NULL OR latitude BETWEEN -90 AND 90")
    op.create_check_constraint("ck_farms_longitude", "farms", "longitude IS NULL OR longitude BETWEEN -180 AND 180")
    op.create_check_constraint("ck_farms_location_pair", "farms", "(latitude IS NULL) = (longitude IS NULL)")

    op.create_table(
        "farm_members",
        sa.Column("farm_id", sa.Uuid, sa.ForeignKey("farms.id"), primary_key=True),
        sa.Column("user_id", sa.Uuid, sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("role", sa.String(16), nullable=False),
        sa.Column("added_at", TS, nullable=False),
        sa.Column("added_by", sa.Uuid, sa.ForeignKey("users.id"), nullable=False),
        sa.Column("removed_at", TS),
        sa.CheckConstraint("role IN ('operator')", name="ck_farm_members_role"),
    )
    op.create_index("ix_farm_members_user", "farm_members", ["user_id"])

    op.create_table(
        "trap_counts",
        sa.Column("id", sa.Uuid, **UUID_PK),
        _farm_fk(),
        sa.Column("trap", sa.String(32), nullable=False),
        sa.Column("night", sa.Date, nullable=False),
        sa.Column("moths", sa.Integer, nullable=False),
        *_recorded(),
        sa.CheckConstraint("moths BETWEEN 0 AND 10000", name="ck_trap_counts_moths"),
    )
    # One live count per trap and night; a new entry for the same night replaces it.
    op.create_index("uq_trap_counts_live", "trap_counts", ["farm_id", "trap", "night"], unique=True, postgresql_where=sa.text("deleted_at IS NULL"))

    op.create_table(
        "scouting_observations",
        sa.Column("id", sa.Uuid, **UUID_PK),
        _farm_fk(),
        sa.Column("observed_on", sa.Date, nullable=False),
        sa.Column("observation", sa.String(64), nullable=False),
        sa.Column("count", sa.Integer, nullable=False),
        sa.Column("units", sa.Integer, nullable=False),
        sa.Column("row_no", sa.Integer),
        sa.Column("segment_no", sa.Integer),
        *_recorded(),
        sa.CheckConstraint("count BETWEEN 0 AND 100000", name="ck_scouting_count"),
        sa.CheckConstraint("units BETWEEN 1 AND 10000", name="ck_scouting_units"),
    )
    op.create_index("ix_scouting_farm_day", "scouting_observations", ["farm_id", sa.text("observed_on DESC")])

    op.create_table(
        "detection_confirmations",
        sa.Column("id", sa.Uuid, **UUID_PK),
        _farm_fk(),
        sa.Column("observed_on", sa.Date, nullable=False),
        sa.Column("row_no", sa.Integer, nullable=False),
        sa.Column("segment_no", sa.Integer, nullable=False),
        sa.Column("class_name", sa.String(32), nullable=False),
        sa.Column("verdict", sa.String(16), nullable=False),
        sa.Column("source_msg_id", sa.String(26)),
        *_recorded(),
        sa.CheckConstraint("verdict IN ('confirmed', 'rejected')", name="ck_confirmations_verdict"),
    )
    op.create_index("ix_confirmations_farm_day", "detection_confirmations", ["farm_id", sa.text("observed_on DESC")])

    op.create_table(
        "farm_advisories",
        sa.Column("id", sa.Uuid, **UUID_PK),
        _farm_fk(),
        sa.Column("key", sa.String(96), nullable=False),
        sa.Column("type", sa.String(16), nullable=False),
        sa.Column("pest", sa.String(48)),
        sa.Column("reason", sa.String(512), nullable=False),
        sa.Column("segments", postgresql.JSONB, nullable=False),
        sa.Column("text_en", sa.Text, nullable=False),
        sa.Column("text_ta", sa.Text, nullable=False),
        sa.Column("active", sa.Boolean, nullable=False),
        sa.Column("created_at", TS, nullable=False),
        sa.Column("updated_at", TS, nullable=False),
        sa.Column("notified_at", TS),
        sa.Column("resolved_at", TS),
        sa.CheckConstraint(
            "type IN ('PICK_NOW', 'PICK_LIST', 'PEST_ETL', 'SPOT_TREAT', 'PEST_ALERT', 'SPRAY_BLOCKED')", name="ck_advisories_type",
        ),
        sa.CheckConstraint("active OR resolved_at IS NOT NULL", name="ck_advisories_resolved"),
    )
    op.create_index("uq_advisories_active_key", "farm_advisories", ["farm_id", "key"], unique=True, postgresql_where=sa.text("active"))
    op.create_index("ix_advisories_farm_created", "farm_advisories", ["farm_id", sa.text("created_at DESC")])

    op.create_table(
        "farm_status",
        sa.Column("farm_id", sa.Uuid, sa.ForeignKey("farms.id"), primary_key=True),
        sa.Column("computed_at", TS, nullable=False),
        sa.Column("doc", postgresql.JSONB, nullable=False),
    )
    op.create_table(
        "farm_weather",
        sa.Column("farm_id", sa.Uuid, sa.ForeignKey("farms.id"), primary_key=True),
        sa.Column("fetched_at", TS, nullable=False),
        sa.Column("doc", postgresql.JSONB, nullable=False),
    )


def downgrade() -> None:
    for table in ("farm_weather", "farm_status", "farm_advisories", "detection_confirmations", "scouting_observations", "trap_counts", "farm_members"):
        op.drop_table(table)
    for name in ("ck_farms_location_pair", "ck_farms_longitude", "ck_farms_latitude"):
        op.drop_constraint(name, "farms", type_="check")
    op.drop_column("farms", "longitude")
    op.drop_column("farms", "latitude")
