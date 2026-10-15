"""Phase II contract: optional battery reading, air humidity and dew point on telemetry.
New event kinds (event/scan, event/pick) need no schema change: they are stored in
device_events with event_type 'scan' / 'pick'.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-14
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("telemetry", "battery_pct", existing_type=sa.Float, nullable=True)
    op.add_column("telemetry", sa.Column("air_rh_pct", sa.Float))
    op.add_column("telemetry", sa.Column("dewpoint_c", sa.Float))


def downgrade() -> None:
    op.drop_column("telemetry", "dewpoint_c")
    op.drop_column("telemetry", "air_rh_pct")
    # Rows without a battery reading cannot satisfy NOT NULL again; remove them explicitly first.
    op.execute("DELETE FROM telemetry WHERE battery_pct IS NULL")
    op.alter_column("telemetry", "battery_pct", existing_type=sa.Float, nullable=False)
