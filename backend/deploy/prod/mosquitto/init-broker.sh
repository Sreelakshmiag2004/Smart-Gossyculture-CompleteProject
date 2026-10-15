#!/bin/sh
# Builds the Mosquitto password file and installs the TLS certificate (staging/production).
# Runs once (as root, no network) in the mosquitto image before the broker starts.
#
# Inputs:
#   /run/gossy-secrets/mqtt/<account>.password  rendered from AWS Secrets Manager (tmpfs)
#   /mosquitto/certs/{cert.crt,cert.key}        publicly trusted certificate for the MQTT host,
#                                               synced from Caddy by bin/sync-broker-cert.sh
#
# Device accounts: production device credentials are unresolved (U-7). Only service accounts
# exist in production; staging may add temporary test-device passwords (named in the secret).
set -eu

SRC=/run/gossy-secrets/mqtt
CERTS=/mosquitto/certs
DST=/mosquitto/generated

for f in "$CERTS/cert.crt" "$CERTS/cert.key"; do
  if [ ! -s "$f" ]; then
    echo "missing $f - run bin/sync-broker-cert.sh after Caddy has obtained the certificate" >&2
    exit 1
  fi
done
if grep -q "NOT FOR PRODUCTION" "$CERTS/cert.crt"; then
  echo "refusing to install a development certificate" >&2
  exit 1
fi

mkdir -p "$DST"
rm -f "$DST/passwd.tmp"
touch "$DST/passwd.tmp"
chmod 0600 "$DST/passwd.tmp"
count=0
for f in "$SRC"/*.password; do
  user=$(basename "$f" .password)
  mosquitto_passwd -b "$DST/passwd.tmp" "$user" "$(cat "$f")"
  count=$((count + 1))
done
mv "$DST/passwd.tmp" "$DST/passwd"

cp "$CERTS/cert.crt" "$DST/cert.crt"
cp "$CERTS/cert.key" "$DST/cert.key"
# cafile: the chain presented by the server (only used for client-certificate verification,
# which is disabled until U-7; Mosquitto requires the directive for a TLS listener).
cp "$CERTS/cert.crt" "$DST/chain.crt"
# The healthcheck password is NOT copied here (persistent volume): the broker container reads it
# from tmpfs (/run/gossy-secrets/health).
chown -R mosquitto:mosquitto "$DST"
chmod 0700 "$DST"
chmod 0600 "$DST"/*
echo "broker init complete: $count MQTT accounts, TLS certificate installed"
