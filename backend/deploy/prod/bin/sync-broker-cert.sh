#!/usr/bin/env bash
# Copy the certificate Caddy obtained for GOSSY_MQTT_PUBLIC_HOST to Mosquitto and restart the
# broker if it changed (renewals). Run by deploy.sh and daily by gossy-cert-sync.timer.
# A broker restart is safe: persistent sessions and queued messages are on disk (Phase 2.5).
set -euo pipefail
ENV_FILE=${GOSSY_ENV_FILE:-/etc/gossy/gossy.env}
set -a; . "$ENV_FILE"; set +a
DATA=${GOSSY_DATA_ROOT:-/srv/gossy}
HOST=${GOSSY_MQTT_PUBLIC_HOST:?}
DEST=$DATA/broker/certs
COMPOSE="docker compose --env-file $ENV_FILE --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml ${GOSSY_COMPOSE_EXTRA:-}"

wait_s=${1:-0}
deadline=$(( $(date +%s) + wait_s ))
while :; do
  CRT=$(find "$DATA/caddy/data/caddy/certificates" -path "*/$HOST/$HOST.crt" 2>/dev/null | head -1 || true)
  [ -n "$CRT" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "no certificate for $HOST yet (is DNS pointing at this host? U-6)" >&2
    exit 1
  fi
  sleep 5
done
KEY=${CRT%.crt}.key
mkdir -p "$DEST"
# Internal-CA profile only (local rehearsal): publish Caddy's root certificate (public material)
# readable for non-root clients. With Let's Encrypt this file does not exist.
INTERNAL_ROOT="$DATA/caddy/data/caddy/pki/authorities/local/root.crt"
if [ -f "$INTERNAL_ROOT" ]; then install -m 0644 "$INTERNAL_ROOT" "$DEST/internal-root.crt"; fi
if cmp -s "$CRT" "$DEST/cert.crt" && cmp -s "$KEY" "$DEST/cert.key"; then
  echo "broker certificate unchanged"
  exit 0
fi
install -m 0644 "$CRT" "$DEST/cert.crt"
install -m 0600 "$KEY" "$DEST/cert.key"
echo "broker certificate updated from $CRT"
if $COMPOSE ps --status running --services 2>/dev/null | grep -qx mosquitto; then
  $COMPOSE up -d --force-recreate mosquitto-init mosquitto
fi
