#!/usr/bin/env bash
# LOCAL REHEARSAL of the production deployment procedure (no AWS account available - U-5).
#
#   bash deploy/prod/rehearsal/run-rehearsal.sh up <host-name> <api-port> <mqtt-port> <image-tag>
#   bash deploy/prod/rehearsal/run-rehearsal.sh exec <host-name> <command...>
#   bash deploy/prod/rehearsal/run-rehearsal.sh down <host-name>
#
# "up" provisions a CLEAN Docker-in-Docker host and performs the documented procedure on it:
#   image delivery (docker save/load stands in for ECR push/pull) -> deploy bundle ->
#   /etc/gossy/gossy.env -> fresh secret document (stands in for Secrets Manager) ->
#   install.sh -> bin/deploy.sh <tag>
# Off-host backups go to the Docker volume gossy-rehearsal-offhost (stands in for S3).
set -euo pipefail
export MSYS_NO_PATHCONV=1       # Git Bash on Windows: do not rewrite /etc/... container paths
cd "$(dirname "$0")/../../.."   # backend/
HERE=deploy/prod/rehearsal
ACTION=${1:?up|exec|down}; HOST=${2:?host container name}
IMAGES=(timescale/timescaledb:2.30.2-pg17 eclipse-mosquitto:2.0.22 caddy:2.11.4)
ex() { docker exec -i "$HOST" "$@"; }

case $ACTION in
up)
  API_PORT=${3:?}; MQTT_PORT=${4:?}; TAG=${5:?}
  if [ "${REUSE:-0}" != 1 ]; then  # REUSE=1: keep an existing host and its loaded images (re-runs only)
    docker build -q -t gossy-rehearsal-host -f $HERE/Dockerfile.host $HERE >/dev/null
    docker rm -f "$HOST" >/dev/null 2>&1 || true
    docker run -d --privileged --name "$HOST" --hostname "$HOST" \
      -p "127.0.0.1:$API_PORT:443" -p "127.0.0.1:$MQTT_PORT:8883" \
      -v gossy-rehearsal-offhost:/srv/offhost-backups gossy-rehearsal-host \
      dockerd --host=unix:///var/run/docker.sock >/dev/null  # local socket only, like the EC2 host (no TCP API)
  fi
  for _ in $(seq 1 60); do ex docker info >/dev/null 2>&1 && break; sleep 1; done
  echo "[$HOST] loading images (stands in for ECR pull)"
  for i in "${IMAGES[@]}"; do docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null; done
  missing=(); for i in "gossy-backend:$TAG" gossy-backend:dev "${IMAGES[@]}"; do ex docker image inspect "$i" >/dev/null 2>&1 || missing+=("$i"); done
  [ ${#missing[@]} -eq 0 ] || docker save "${missing[@]}" | ex docker load -q
  echo "[$HOST] installing deploy bundle"
  tar -C deploy/prod -cf - . | ex sh -c 'rm -rf /tmp/bundle && mkdir -p /tmp/bundle && tar -xf - -C /tmp/bundle'
  ex mkdir -p /etc/gossy /opt/gossy/scripts
  ex sh -c 'cat > /etc/gossy/gossy.env' < $HERE/rehearsal.env
  ex sh -c 'python3 /tmp/bundle/rehearsal/make-secrets.py staging > /etc/gossy/rehearsal-secrets.json && chmod 0600 /etc/gossy/rehearsal-secrets.json'
  ex env GOSSY_NO_SYSTEMD=1 bash /tmp/bundle/install.sh
  ex cp -r /tmp/bundle/rehearsal /opt/gossy/
  tar -C scripts -cf - durability_check.sh | ex tar -xf - -C /opt/gossy/scripts
  if [ "${NODEPLOY:-0}" = 1 ]; then  # clean host for a restore drill: bundle + secrets, no database yet
    echo "[$HOST] provisioned without deployment (restore target)"
    exit 0
  fi
  echo "[$HOST] deploy.sh $TAG"
  ex bash -c "set -a; . /etc/gossy/gossy.env; set +a; /opt/gossy/bin/deploy.sh $TAG"
  ;;
exec)
  shift 2
  ex bash -c "set -a; . /etc/gossy/gossy.env; set +a; cd /opt/gossy; COMPOSE=\"docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml \$GOSSY_COMPOSE_EXTRA\"; export GOSSY_COMPOSE=\"\$COMPOSE\"; $*"
  ;;
down)
  docker rm -f "$HOST" >/dev/null 2>&1 || true
  ;;
esac
