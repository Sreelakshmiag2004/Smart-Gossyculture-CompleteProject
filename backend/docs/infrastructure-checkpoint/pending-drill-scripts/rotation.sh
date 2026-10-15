set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
cd /opt/gossy
TAG=$(cat /tmp/tag)
RUN="$C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli"
OLD_REV=$(cat /run/gossy-secrets/.revision)
install -m 0600 /run/gossy-secrets/db/app.password /run/gossy-secrets/.old-app
install -m 0600 /run/gossy-secrets/mqtt/svc-ingest.password /run/gossy-secrets/.old-mqtt
echo "== before rotation: secrets revision $OLD_REV"
# Stands in for: terraform apply with secret_version + 1 (new random values in Secrets Manager).
python3 /opt/gossy/rehearsal/make-secrets.py staging > /etc/gossy/rehearsal-secrets.json
echo "== deploy.sh $TAG (same image, new secret document)"
/opt/gossy/bin/deploy.sh "$TAG" 2>&1 | grep -E 'deploy:|reconciled|prodcheck:|certificate'; echo "deploy exit=${PIPESTATUS[0]}"
NEW_REV=$(cat /run/gossy-secrets/.revision)
echo "== after rotation: secrets revision $NEW_REV (changed: $([ "$OLD_REV" != "$NEW_REV" ] && echo yes || echo NO))"
docker ps --format '{{.Names}} up {{.RunningFor}}' | sort
echo "== old database password is rejected, new one is accepted"
docker cp /run/gossy-secrets/.old-app gossy-timescaledb-1:/tmp/old-app >/dev/null
$C exec -T timescaledb sh -c 'PGPASSWORD=$(cat /tmp/old-app) psql -h 127.0.0.1 -U gossy_app -d gossy -Atc "select 1" 2>&1 | tail -1; rm -f /tmp/old-app; PGPASSWORD=$(cat /run/gossy-secrets/db/app.password) psql -h 127.0.0.1 -U gossy_app -d gossy -Atc "select 1" | sed "s/^1$/new password accepted/"'
echo "== old MQTT service password is rejected; ingest is connected with the new one"
OLD_MQTT=$(cat /run/gossy-secrets/.old-mqtt)
$C exec -T -e OLD="$OLD_MQTT" mosquitto sh -c 'mosquitto_sub -h localhost -p 8883 --cafile "$GOSSY_BROKER_PROBE_CA" --insecure -u svc-ingest -P "$OLD" -V mqttv5 -t bollbot/v1/x/status -i rotation-old -E -W 5 2>&1 | tail -1'
curl -fsS http://127.0.0.1:8001/readyz | python3 -c "import json,sys; d=json.load(sys.stdin); print('ingest:', d['status'], d['checks'])"
rm -f /run/gossy-secrets/.old-app /run/gossy-secrets/.old-mqtt
echo "== data flows with the new secrets"
SPEC=$($RUN publish 3 2>/dev/null | tail -1); $RUN verify "$SPEC" --timeout 60 2>/dev/null | tail -1 | cut -c1-170
