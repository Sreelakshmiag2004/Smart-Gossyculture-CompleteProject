set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
cd /opt/gossy
RUN="$C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli"
echo "== state after the host came back (Docker restarted the containers; no operator action yet)"
echo "secrets tmpfs mounted: $(mountpoint -q /run/gossy-secrets && echo yes || echo 'NO (tmpfs is gone, as designed: secrets are never on disk)')"
docker ps -a --format '{{.Names}}\t{{.Status}}' | sort
echo "== boot units in order: gossy-secrets.service (render-secrets.sh) then gossy.service (compose up -d --wait)"
/opt/gossy/bin/render-secrets.sh --from-file "$GOSSY_SECRETS_FILE" 2>&1 | tail -1
$C up -d --wait 2>&1 | grep -v -E '^\s*(Container|Network|Volume|Image) '; echo "compose up exit=${PIPESTATUS[0]}"
docker ps -a --format '{{.Names}}\t{{.Status}}' | sort
curl -fsS http://127.0.0.1:8000/readyz | cut -c1-18; echo
curl -fsS http://127.0.0.1:8001/readyz | python3 -c "import json,sys; d=json.load(sys.stdin); print('ingest:', d['status'], d['checks'], 'condition', d['info']['condition'])"
echo "== data survived and new data flows"
$C exec -T timescaledb psql -U postgres -d gossy -Atc "select 'ledger rows after reboot: ' || count(*) from ingested_messages"
SPEC=$($RUN publish 3 2>/dev/null | tail -1); $RUN verify "$SPEC" --timeout 90 2>/dev/null | tail -1 | cut -c1-170
