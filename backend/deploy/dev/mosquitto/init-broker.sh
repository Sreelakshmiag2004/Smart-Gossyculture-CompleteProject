#!/bin/sh
# Builds the Mosquitto password file and TLS material from the development secrets volume.
# Runs once (as root) in the mosquitto image before the broker starts. DEVELOPMENT ONLY.
set -eu

SRC=/run/gossy-secrets
DST=/mosquitto/generated

if [ ! -f "$SRC/DEVELOPMENT_ONLY" ]; then
  echo "development secrets not found - run the bootstrap service first:" >&2
  echo "  docker compose -f deploy/dev/compose.yaml --profile setup run --rm bootstrap" >&2
  exit 1
fi

mkdir -p "$DST"
rm -f "$DST/passwd.tmp"
touch "$DST/passwd.tmp"
chmod 0600 "$DST/passwd.tmp"
count=0
for f in "$SRC"/mqtt/*.password; do
  user=$(basename "$f" .password)
  mosquitto_passwd -b "$DST/passwd.tmp" "$user" "$(cat "$f")"
  count=$((count + 1))
done
mv "$DST/passwd.tmp" "$DST/passwd"

cp "$SRC/certs/ca.crt" "$SRC/certs/broker.crt" "$SRC/certs/broker.key" "$DST/"
# Healthcheck credential only (the broker container gets no other secret from the volume).
cp "$SRC/mqtt/svc-health.password" "$DST/health.password"
chown -R mosquitto:mosquitto "$DST"
chmod 0700 "$DST"
chmod 0600 "$DST"/*
echo "broker init complete: $count MQTT accounts, TLS material installed"
