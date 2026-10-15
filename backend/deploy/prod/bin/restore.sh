#!/usr/bin/env bash
# Restore a backup into a CLEAN environment (new host, or a new empty /srv/gossy/pgdata).
#
#   restore.sh s3://bucket/<env>/db/gossy-...dump <image-tag>
#   restore.sh local:/path/gossy-...dump <image-tag>   # LOCAL REHEARSAL ONLY
# <image-tag>: an application release whose migration head matches the backup (see .meta.json).
#
# Refuses to run if database "gossy" already contains application tables: restoring over live
# data is never done by this script. Procedure (TimescaleDB-documented):
#   fresh database (roles + extension from 10-init-roles.sh) -> version check ->
#   timescaledb_pre_restore() -> pg_restore -> timescaledb_post_restore() -> ANALYZE ->
#   start the stack (migrations verify the schema head) -> readiness.
set -euo pipefail
SRC=${1:?usage: restore.sh <s3-uri|local:path> <image-tag>}
TAG=${2:?usage: restore.sh <s3-uri|local:path> <image-tag>}
ENV_FILE=${GOSSY_ENV_FILE:-/etc/gossy/gossy.env}
set -a; . "$ENV_FILE"; set +a
# Environment overrides --env-file in Compose. /etc/gossy/release.env is NOT written here: a
# refused restore must leave a running host exactly as it was (bin/deploy.sh writes it at the end).
export GOSSY_IMAGE_TAG="$TAG"
DATA=${GOSSY_DATA_ROOT:-/srv/gossy}
COMPOSE="docker compose --env-file $ENV_FILE --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml ${GOSSY_COMPOSE_EXTRA:-}"
WORK="$DATA/backups/restore"
log() { printf '%s restore: %s\n' "$(date -u +%FT%TZ)" "$*"; }
psql_q() { $COMPOSE exec -T timescaledb psql -U postgres -d gossy -v ON_ERROR_STOP=1 -Atc "$1"; }

mkdir -p "$WORK"; chmod 0700 "$WORK"
trap 'rm -rf "${WORK:?}"/*' EXIT   # never leave a database dump on the data volume
NAME=$(basename "${SRC#local:}")
case "$SRC" in
  s3://*) for f in "$NAME" "$NAME.sha256" "$NAME.meta.json"; do aws s3 cp --only-show-errors --region "$GOSSY_AWS_REGION" "$(dirname "$SRC")/$f" "$WORK/$f"; done ;;
  local:*) cp "${SRC#local:}" "${SRC#local:}.sha256" "${SRC#local:}.meta.json" "$WORK/" ;;
  *) log "unsupported source $SRC"; exit 1 ;;
esac
( cd "$WORK" && sha256sum -c "$NAME.sha256" )

log "starting database only"
if [ -n "${GOSSY_SECRETS_FILE:-}" ]; then /opt/gossy/bin/render-secrets.sh --from-file "$GOSSY_SECRETS_FILE"; else /opt/gossy/bin/render-secrets.sh; fi
mkdir -p "$DATA"/pgdata
$COMPOSE up -d --wait timescaledb
TABLES=$(psql_q "select count(*) from information_schema.tables where table_schema='public' and table_name in ('ingested_messages','users','alembic_version')")
[ "$TABLES" = 0 ] || { log "database is not empty ($TABLES application tables) - refusing to restore over existing data (nothing was changed)"; exit 1; }
# Only now (empty database confirmed) stop anything that could write during the restore.
$COMPOSE stop api ingest caddy mosquitto >/dev/null 2>&1 || true

WANT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['versions']['timescaledb'])" "$WORK/$NAME.meta.json")
HAVE=$(psql_q "select extversion from pg_extension where extname='timescaledb'")
[ "$WANT" = "$HAVE" ] || { log "TimescaleDB version mismatch: backup $WANT, server $HAVE"; exit 1; }

log "restoring $NAME (TimescaleDB $HAVE)"
psql_q "select timescaledb_pre_restore()" >/dev/null
$COMPOSE exec -T timescaledb pg_restore -U postgres -d gossy --exit-on-error --single-transaction < "$WORK/$NAME" \
  || { log "pg_restore failed"; psql_q "select timescaledb_post_restore()" >/dev/null; exit 1; }
psql_q "select timescaledb_post_restore()" >/dev/null
psql_q "analyze" >/dev/null
log "restored: $(psql_q "select format('alembic=%s ledger=%s telemetry=%s events=%s alerts=%s users=%s devices=%s', (select version_num from alembic_version), (select count(*) from ingested_messages), (select count(*) from telemetry), (select count(*) from device_events), (select count(*) from alerts), (select count(*) from users), (select count(*) from devices))")"

log "starting the application stack (same staged start as a deployment: broker certificate first)"
/opt/gossy/bin/deploy.sh "$TAG"
log "restore complete"
