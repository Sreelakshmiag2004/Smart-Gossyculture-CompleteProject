"""Table definitions used by the repositories and query modules.

The schema itself is owned by Alembic (migrations/versions). Keep the two in sync; the
integration tests insert and query through these definitions against the migrated database.
"""

from __future__ import annotations

from sqlalchemy import BigInteger, Boolean, Column, DateTime, Float, ForeignKey, Identity, Integer, MetaData, String, Table, Text, Uuid, text
from sqlalchemy.dialects.postgresql import JSONB

metadata = MetaData()
_UUID_DEFAULT = text("gen_random_uuid()")

# --------------------------------------------------------------------------- ingestion (Phase 1)

# Idempotency ledger: one row per accepted message. The primary key on msg_id is what makes
# QoS 1 redelivery and post-reconnect replays duplicate-free. Phase 2 adds ingest_seq (a
# server-assigned, monotonically increasing cursor for WebSocket resume) and data (the
# validated payload, so any message kind can be replayed).
ingested_messages = Table(
    "ingested_messages",
    metadata,
    Column("msg_id", String(26), primary_key=True),
    Column("device_id", String(64), nullable=False),
    Column("kind", String(32), nullable=False),
    Column("schema_id", String(64), nullable=False),
    Column("seq", BigInteger, nullable=False),
    Column("device_ts", DateTime(timezone=True), nullable=False),
    Column("received_at", DateTime(timezone=True), nullable=False),
    Column("ingest_seq", BigInteger, Identity(always=True), nullable=False, unique=True),
    Column("data", JSONB),
)

# TimescaleDB hypertable partitioned on "time" (device timestamp).
telemetry = Table(
    "telemetry",
    metadata,
    Column("time", DateTime(timezone=True), nullable=False),
    Column("device_id", String(64), nullable=False),
    Column("msg_id", String(26), nullable=False),
    Column("battery_pct", Float),  # nullable since 0003: omitted when the device has no battery monitor
    Column("moisture_rh_pct", Float),
    Column("air_temp_c", Float),
    Column("bolls_harvested_total", BigInteger),
    Column("solar_active", Boolean),
    Column("air_rh_pct", Float),   # 0003: air humidity (BME280), weather only
    Column("dewpoint_c", Float),   # 0003
)

# TimescaleDB hypertable for pest / spray / harvest events.
device_events = Table(
    "device_events",
    metadata,
    Column("time", DateTime(timezone=True), nullable=False),
    Column("device_id", String(64), nullable=False),
    Column("msg_id", String(26), nullable=False),
    Column("event_type", String(32), nullable=False),
    Column("data", JSONB, nullable=False),
)

# Latest known state per device. state_at is the backend RECEIPT time of the status message.
device_status = Table(
    "device_status",
    metadata,
    Column("device_id", String(64), primary_key=True),
    Column("state", String(16)),
    Column("state_at", DateTime(timezone=True)),
    Column("last_seen_at", DateTime(timezone=True)),
    Column("last_msg_id", String(26)),
)

# Dead-letter record for messages that failed validation. Excerpt is truncated.
rejected_messages = Table(
    "rejected_messages",
    metadata,
    Column("id", BigInteger, Identity(always=True), primary_key=True),
    Column("received_at", DateTime(timezone=True), nullable=False),
    Column("topic", String(256), nullable=False),
    Column("reason", String(64), nullable=False),
    Column("detail", String(512)),
    Column("payload_size", Integer, nullable=False),
    Column("payload_excerpt", Text),
)

# --------------------------------------------------------------------------- application (Phase 2)

users = Table(
    "users",
    metadata,
    Column("id", Uuid, primary_key=True, server_default=_UUID_DEFAULT),
    Column("phone_e164", String(16), nullable=False, unique=True),
    Column("display_name", String(80)),
    Column("role", String(16), nullable=False),  # farmer | admin
    Column("status", String(16), nullable=False),  # active | disabled
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("last_login_at", DateTime(timezone=True)),
)

farms = Table(
    "farms",
    metadata,
    Column("id", Uuid, primary_key=True, server_default=_UUID_DEFAULT),
    Column("owner_user_id", Uuid, ForeignKey("users.id"), nullable=False),
    Column("name", String(80), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
)

# Device registry. device_id equals the MQTT username / topic deviceId.
devices = Table(
    "devices",
    metadata,
    Column("device_id", String(64), primary_key=True),
    Column("farm_id", Uuid, ForeignKey("farms.id")),
    Column("display_name", String(80)),
    Column("registration_state", String(16), nullable=False),  # provisioned | active | decommissioned
    Column("claim_code_hash", String(64)),
    Column("claim_code_expires_at", DateTime(timezone=True)),
    Column("registered_at", DateTime(timezone=True), nullable=False),
    Column("registered_by", Uuid, ForeignKey("users.id")),
    Column("claimed_at", DateTime(timezone=True)),
    Column("claimed_by", Uuid, ForeignKey("users.id")),
    Column("decommissioned_at", DateTime(timezone=True)),
)

otp_challenges = Table(
    "otp_challenges",
    metadata,
    Column("id", Uuid, primary_key=True, server_default=_UUID_DEFAULT),
    Column("phone_e164", String(16), nullable=False),
    Column("code_hash", String(64), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Column("attempts", Integer, nullable=False),
    Column("consumed_at", DateTime(timezone=True)),
)

auth_sessions = Table(
    "auth_sessions",
    metadata,
    Column("id", Uuid, primary_key=True, server_default=_UUID_DEFAULT),
    Column("user_id", Uuid, ForeignKey("users.id"), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Column("revoked_at", DateTime(timezone=True)),
    Column("revoke_reason", String(32)),
)

# Opaque refresh tokens, stored only as SHA-256 hashes; single use (rotation).
refresh_tokens = Table(
    "refresh_tokens",
    metadata,
    Column("token_hash", String(64), primary_key=True),
    Column("session_id", Uuid, ForeignKey("auth_sessions.id"), nullable=False),
    Column("issued_at", DateTime(timezone=True), nullable=False),
    Column("expires_at", DateTime(timezone=True), nullable=False),
    Column("used_at", DateTime(timezone=True)),
)

# Alerts are derived by the ingest service from ingested messages, in the same transaction.
# UNIQUE(source_msg_id, alert_type) keeps alert creation idempotent.
alerts = Table(
    "alerts",
    metadata,
    Column("id", Uuid, primary_key=True, server_default=_UUID_DEFAULT),
    Column("device_id", String(64), nullable=False),
    Column("alert_type", String(32), nullable=False),
    Column("severity", String(16), nullable=False),
    Column("status", String(16), nullable=False),  # open | acknowledged
    Column("source_msg_id", String(26), nullable=False),
    Column("occurred_at", DateTime(timezone=True), nullable=False),
    Column("created_at", DateTime(timezone=True), nullable=False),
    Column("details", JSONB, nullable=False),
    Column("acknowledged_at", DateTime(timezone=True)),
    Column("acknowledged_by", Uuid, ForeignKey("users.id")),
)

audit_log = Table(
    "audit_log",
    metadata,
    Column("id", BigInteger, Identity(always=True), primary_key=True),
    Column("ts", DateTime(timezone=True), nullable=False),
    Column("actor_user_id", Uuid),
    Column("action", String(64), nullable=False),
    Column("outcome", String(16), nullable=False),  # success | failure | denied
    Column("target", String(128)),
    Column("request_id", String(64)),
    Column("client_ip", String(64)),
    Column("details", JSONB, nullable=False),
)
