# Smart Gossyculture / BOLLBOT — backend (Phase 2: application backend and API)

Python/FastAPI backend for the approved Phase 0 architecture:

```
Raspberry Pi ──MQTT/TLS──► Mosquitto ──► ingest (FastAPI worker) ──► PostgreSQL + TimescaleDB
Flutter app  ──HTTPS/WSS──► api (FastAPI)  ◄── LISTEN/NOTIFY ────────  PostgreSQL + TimescaleDB
```

**Status: development only. Nothing here is production-ready or deployed.**
v1 is monitoring-only: MQTT is ingestion-only, the backend cannot publish to devices (broker
ACL), and neither the REST API nor the WebSocket has any device-control operation.

Contracts (what the Flutter app will consume):

| Contract | File |
|---|---|
| REST `/api/v1` (OpenAPI 3.1, drift-checked by a unit test) | `docs/openapi.json` |
| Live monitoring WebSocket `gossy.ws.v1` | `docs/websocket-contract.md` |
| Device → backend MQTT `bollbot/v1` | `docs/mqtt-contract.md` |

Authentication is phone OTP. **No SMS is sent**: development/staging use allow-listed test
numbers in the unassigned `+999` range with a fixed code from the secrets volume
(`auth/test-otp.code`); production refuses test mode and answers 503 until an SMS provider is
chosen (U-4). The admin role can only be granted with the operator CLI:
`docker compose -f deploy/dev/compose.yaml exec api python -m gossy.manage set-role --phone +99900000009 --role admin`.

## Layout

| Path | Responsibility |
|---|---|
| `src/gossy/config.py` | Environment-variable settings; secret files; staging/production safety rules |
| `src/gossy/logging_setup.py` | JSON structured logging with secret redaction |
| `src/gossy/contracts/` | MQTT topic naming and typed message schemas (shared by ingest and simulator) |
| `src/gossy/db/` | Engine, table definitions, migration-head lookup |
| `src/gossy/health/` | `/healthz` (liveness) and `/readyz` (readiness) |
| `src/gossy/api/` | API service (`uvicorn --factory gossy.api.app:create_app`), errors, pagination, middleware |
| `src/gossy/auth/`, `src/gossy/security/` | OTP sign-in, sessions, JWT access + rotating refresh tokens, rate limits |
| `src/gossy/devices/` | Farms, device registry (provision → claim → active → decommissioned), access rule |
| `src/gossy/telemetry/`, `src/gossy/alerts/` | Telemetry / events / detections queries; alert rules and endpoints |
| `src/gossy/realtime/` | WebSocket endpoint, event hub, PostgreSQL LISTEN loop |
| `src/gossy/audit.py`, `src/gossy/manage.py` | Append-only audit log; operator CLI (grant admin) |
| `src/gossy/ingest/` | Validation → idempotent persistence; reconnecting MQTT consumer; ingest service app |
| `src/gossy_sim/` | Development-only device simulator (`sim-*` device IDs only) |
| `src/gossy_devtools/bootstrap.py` | Generates development-only secrets and a dev CA into a Docker volume |
| `migrations/` | Alembic migrations (run with the schema-owner role) |
| `deploy/dev/` | Docker Compose development stack (Mosquitto + TimescaleDB configs) |
| `tests/unit`, `tests/integration` | Unit tests (no services) / integration tests (Compose stack) |

## Run the development stack

Requires Docker Desktop. From this `backend/` directory:

```bash
# 1. one-time (and after upgrading to Phase 2, to add the auth keys): generate
#    development-only secrets into the gossy-dev_gossy-secrets volume
docker compose -f deploy/dev/compose.yaml --profile setup run --rm bootstrap

# 2. start database, broker, migrations, api, ingest
docker compose -f deploy/dev/compose.yaml up -d --build

# 3. optional: synthetic device publishing every 5 s
docker compose -f deploy/dev/compose.yaml --profile simulator up -d simulator

# health
curl http://127.0.0.1:8000/healthz   # api liveness
curl http://127.0.0.1:8000/readyz    # api readiness (database, timescaledb, migrations)
curl http://127.0.0.1:8001/readyz    # ingest readiness (database, mqtt) + counters
# API docs (development only): http://127.0.0.1:8000/docs
```

Sign in against the dev stack (test number, fixed code; nothing is sent):

```bash
docker run --rm -v gossy-dev_gossy-secrets:/s alpine cat /s/auth/test-otp.code
curl -X POST localhost:8000/api/v1/auth/otp/request -H 'content-type: application/json' -d '{"phone":"+99900000001"}'
curl -X POST localhost:8000/api/v1/auth/otp/verify  -H 'content-type: application/json' -d '{"phone":"+99900000001","code":"<code>"}'
```

Host ports (127.0.0.1 only): API `8000`, ingest health `8001`, broker `18883` (TLS; inside the
Compose network it is `mosquitto:8883`). 8883 is not used on the host because Windows often
reserves it; override with `GOSSY_DEV_MQTT_HOST_PORT`. The database is not published.

## Tests

```bash
# unit tests (no services needed)
docker compose -f deploy/dev/compose.yaml run --rm --no-deps tests pytest
# integration tests (starts/uses the stack) - includes crash-injection tests A/B/C
docker compose -f deploy/dev/compose.yaml --profile test run --rm tests
# durability scenarios needing Docker control (database outage/restart, broker restart/kill,
# ingest stop/kill); takes ~6 minutes
bash scripts/durability_check.sh
```

Ingestion durability (Phase 2.5): the ingest service acknowledges an MQTT message only after its
outcome is committed; database outages are retried without limit while the broker keeps the
messages; `msgId` makes redeliveries harmless. See "Delivery guarantees" in
`docs/mqtt-contract.md`.

## Secrets

* No credentials are stored in this repository. `.env.dev.example` documents variables only.
* Development secrets are random, prefixed `devonly-`, and live only in a Docker volume next
  to a `DEVELOPMENT_ONLY` marker. `staging`/`production` refuse to start with them.
* The dev CA is named "NOT FOR PRODUCTION". Production TLS and device credentials are
  unresolved (U-6, U-7) and not implemented.
* Auth keys (`auth/jwt-signing.key`, `auth/otp-hmac.key`) and the test OTP code are
  development-only files in the same volume; staging/production refuse them.

Reset everything (destroys dev data and secrets): `docker compose -f deploy/dev/compose.yaml down -v`.
