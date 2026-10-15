#!/usr/bin/env bash
# Deploy (or upgrade) the stack on the host. Run as root via SSM Run Command:
#
#   /opt/gossy/bin/deploy.sh <image-tag>
#
# 0. refresh non-secret settings (SSM parameter)  1. render secrets (tmpfs)
# 2. registry login + pull pinned images  3. validate configuration
# 4. database + migrations + API + TLS proxy  5. broker certificate  6. broker + ingest
# 7. wait for health and readiness. Idempotent; data on /srv/gossy is never touched.
set -euo pipefail
TAG=${1:?usage: deploy.sh <image-tag>}
ENV_FILE=${GOSSY_ENV_FILE:-/etc/gossy/gossy.env}
/opt/gossy/bin/render-config.sh
set -a; . "$ENV_FILE"; set +a
DATA=${GOSSY_DATA_ROOT:-/srv/gossy}
case "$TAG" in latest|dev|"") echo "refusing unpinned image tag '$TAG'" >&2; exit 1 ;; esac

COMPOSE="docker compose --env-file $ENV_FILE --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml ${GOSSY_COMPOSE_EXTRA:-}"
log() { printf '%s deploy: %s\n' "$(date -u +%FT%TZ)" "$*"; }

mkdir -p "$DATA"/{pgdata,caddy/data,caddy/config,broker/data,broker/generated,broker/certs,backups}
chown 1883:1883 "$DATA/broker/data"

log "rendering secrets"
if [ -n "${GOSSY_SECRETS_FILE:-}" ]; then /opt/gossy/bin/render-secrets.sh --from-file "$GOSSY_SECRETS_FILE"; else /opt/gossy/bin/render-secrets.sh; fi
# Release = image tag + secrets revision. A changed revision (rotation) recreates the
# containers holding credentials; the database roles are reconciled below.
printf 'GOSSY_IMAGE_TAG=%s\nGOSSY_SECRETS_REVISION=%s\n' "$TAG" "$(cat /run/gossy-secrets/.revision)" > /etc/gossy/release.env
# Shell environment overrides --env-file in Compose: pin the values being deployed here too, so a
# stale variable in the caller's environment can never select a different image.
export GOSSY_IMAGE_TAG="$TAG" GOSSY_SECRETS_REVISION="$(cat /run/gossy-secrets/.revision)"

if [ "${GOSSY_REGISTRY_LOGIN:-ecr}" = ecr ]; then
  log "registry login ${GOSSY_IMAGE_REPO%%/*}"
  aws ecr get-login-password --region "$GOSSY_AWS_REGION" | docker login --username AWS --password-stdin "${GOSSY_IMAGE_REPO%%/*}"
  $COMPOSE pull --quiet
fi

log "validating configuration (gossy.prodcheck)"
$COMPOSE --profile ops run --rm --no-deps prodcheck

log "starting database, migrations, API and TLS proxy"
$COMPOSE up -d --wait timescaledb
log "reconciling database role passwords with the current secrets"
$COMPOSE exec -T timescaledb psql -U postgres -d postgres -f /opt/gossy-sql/sync-role-passwords.sql
$COMPOSE up -d --wait api caddy

log "installing broker certificate"
/opt/gossy/bin/sync-broker-cert.sh "${GOSSY_CERT_WAIT_S:-300}"

log "starting broker and ingest"
$COMPOSE up -d --wait --remove-orphans

for port in 8000 8001; do
  curl -fsS "http://127.0.0.1:$port/readyz" >/dev/null || { log "readiness failed on :$port"; exit 1; }
done
log "deployed $TAG; all services healthy and ready"
