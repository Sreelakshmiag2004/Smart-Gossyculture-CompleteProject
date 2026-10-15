#!/usr/bin/env bash
# Install the deploy bundle on the host (run as root by Terraform user-data, and again after
# uploading a new bundle). Copies this directory to /opt/gossy, installs systemd units and the
# CloudWatch agent configuration, and enables the timers. Does not start the stack: that is
# bin/deploy.sh <image-tag>.
set -euo pipefail
SRC=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=/etc/gossy/gossy.env
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE missing (written by user-data)"; exit 1; }
set -a; . "$ENV_FILE"; set +a

install -d -m 0755 /opt/gossy /var/log/gossy
cp -r "$SRC"/compose.yaml "$SRC"/caddy "$SRC"/mosquitto "$SRC"/postgres "$SRC"/bin "$SRC"/cloudwatch /opt/gossy/
chmod 0755 /opt/gossy/bin/*.sh /opt/gossy/mosquitto/init-broker.sh /opt/gossy/postgres/10-init-roles.sh
[ -f /etc/gossy/release.env ] || echo "GOSSY_IMAGE_TAG=unset" > /etc/gossy/release.env

sed -i "s|__ENVIRONMENT__|$GOSSY_ENVIRONMENT|g" /opt/gossy/cloudwatch/prometheus.yaml
sed -i "s|__LOG_GROUP__|$GOSSY_LOG_GROUP|g" /opt/gossy/cloudwatch/amazon-cloudwatch-agent.json
if [ "${GOSSY_NO_SYSTEMD:-}" = 1 ]; then
  # LOCAL REHEARSAL ONLY (container "host" without systemd or the CloudWatch agent).
  echo "bundle installed (no systemd/CloudWatch agent: rehearsal)"
  exit 0
fi
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s \
  -c file:/opt/gossy/cloudwatch/amazon-cloudwatch-agent.json

install -m 0644 "$SRC"/systemd/*.service "$SRC"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable gossy-secrets.service gossy.service gossy-backup.timer gossy-cert-sync.timer
systemctl start gossy-backup.timer gossy-cert-sync.timer
echo "bundle installed; deploy with: /opt/gossy/bin/deploy.sh <image-tag>"
