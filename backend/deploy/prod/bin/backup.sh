#!/usr/bin/env bash
# Logical database backup -> off-server storage. Daily via gossy-backup.timer.
#
#   backup.sh                      # upload to s3://$GOSSY_BACKUP_BUCKET/<env>/db/ (SSE-KMS)
#   GOSSY_BACKUP_DEST=local:/dir backup.sh   # LOCAL REHEARSAL ONLY (no AWS available)
#
# Format: pg_dump custom format of database "gossy" (schema + data, incl. TimescaleDB catalog),
# verified with pg_restore --list before upload, plus a .sha256 and a .meta.json (TimescaleDB
# and PostgreSQL versions - a restore needs the same TimescaleDB version).
# Retention is enforced by the S3 lifecycle rule (deploy/aws/terraform/storage.tf).
# On success a CloudWatch metric Gossy/BackupSucceeded=1 is published; an alarm fires if a
# 24-hour period contains none (deploy/aws/terraform/monitoring.tf, backup_missing).
set -euo pipefail
ENV_FILE=${GOSSY_ENV_FILE:-/etc/gossy/gossy.env}
set -a; . "$ENV_FILE"; set +a
DATA=${GOSSY_DATA_ROOT:-/srv/gossy}
COMPOSE="docker compose --env-file $ENV_FILE --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml ${GOSSY_COMPOSE_EXTRA:-}"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NAME="gossy-${GOSSY_ENVIRONMENT}-${STAMP}.dump"
WORK="$DATA/backups/tmp"
log() { printf '%s backup: %s\n' "$(date -u +%FT%TZ)" "$*"; }

mkdir -p "$WORK"; chmod 0700 "$DATA/backups" "$WORK"
trap 'rm -f "$WORK/$NAME"*' EXIT

log "dumping database"
$COMPOSE exec -T timescaledb pg_dump -U postgres -d gossy -Fc -Z 6 > "$WORK/$NAME"
log "verifying archive ($(du -h "$WORK/$NAME" | cut -f1))"
ENTRIES=$($COMPOSE exec -T timescaledb pg_restore --list < "$WORK/$NAME" | grep -c ';' || true)
[ "$ENTRIES" -gt 10 ] || { log "archive verification failed ($ENTRIES entries)"; exit 1; }
( cd "$WORK" && sha256sum "$NAME" > "$NAME.sha256" )
VERSIONS=$($COMPOSE exec -T timescaledb psql -U postgres -d gossy -Atc \
  "select json_build_object('postgres', current_setting('server_version'), 'timescaledb', (select extversion from pg_extension where extname='timescaledb'), 'alembic', (select version_num from alembic_version))")
printf '{"created":"%s","environment":"%s","archive_entries":%s,"versions":%s}\n' "$STAMP" "$GOSSY_ENVIRONMENT" "$ENTRIES" "$VERSIONS" > "$WORK/$NAME.meta.json"

DEST=${GOSSY_BACKUP_DEST:-s3://${GOSSY_BACKUP_BUCKET:?}/${GOSSY_ENVIRONMENT}/db}
case "$DEST" in
  s3://*)
    for f in "$NAME" "$NAME.sha256" "$NAME.meta.json"; do
      aws s3 cp --only-show-errors --region "$GOSSY_AWS_REGION" --sse aws:kms --sse-kms-key-id "${GOSSY_KMS_KEY_ARN:?}" "$WORK/$f" "$DEST/$f"
    done
    aws cloudwatch put-metric-data --region "$GOSSY_AWS_REGION" --namespace Gossy --metric-name BackupSucceeded \
      --dimensions "Environment=$GOSSY_ENVIRONMENT" --value 1 --unit Count ;;
  local:*)
    mkdir -p "${DEST#local:}"
    cp "$WORK/$NAME" "$WORK/$NAME.sha256" "$WORK/$NAME.meta.json" "${DEST#local:}/" ;;
  *) log "unsupported destination $DEST"; exit 1 ;;
esac
log "backup complete: $DEST/$NAME ($ENTRIES archive entries, versions $VERSIONS)"
