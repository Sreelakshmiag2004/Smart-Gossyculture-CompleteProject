set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
export GOSSY_COMPOSE="$C"
cd /opt/gossy
TAG=$(cat /tmp/tag)
D=$(ls /srv/offhost-backups/gossy-*.dump | tail -1)
echo "== clean host before restore: containers=$(docker ps -aq | wc -l) pgdata=$(ls -A /srv/gossy/pgdata 2>/dev/null | wc -l) files"
echo "== tampered archive is refused"; cp "$D" /tmp/t.dump; cp "$D.meta.json" /tmp/t.dump.meta.json; sed "s/$(basename "$D")/t.dump/" "$D.sha256" > /tmp/t.dump.sha256; printf 'X' | dd of=/tmp/t.dump bs=1 seek=2000 conv=notrunc 2>/dev/null
/opt/gossy/bin/restore.sh local:/tmp/t.dump "$TAG" 2>&1 | tail -2; echo "tampered restore exit=${PIPESTATUS[0]}"; rm -f /tmp/t.dump*
echo "== restore.sh local:$D $TAG"; date -u +%FT%TZ
/opt/gossy/bin/restore.sh "local:$D" "$TAG" 2>&1 | grep -v -E '^\s*(Container|Network|Volume|Image) ' ; echo "restore exit=${PIPESTATUS[0]}"; date -u +%FT%TZ
FP() { $C exec -T timescaledb psql -U postgres -d gossy -At < /tmp/fingerprint.sql; }
echo "== RESTORED fingerprint"; FP > /tmp/restored-fingerprint.txt; cat /tmp/restored-fingerprint.txt
echo "== fingerprint identical to source: $(cmp -s /tmp/restored-fingerprint.txt /srv/offhost-backups/source-fingerprint.txt && echo YES || echo NO)"
echo "== application on the restored host"; $C ps -a --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null
curl -fsS http://127.0.0.1:8000/readyz; echo; curl -fsS http://127.0.0.1:8001/readyz; echo
echo "== RESTORED data served by the API"; $C --profile test run --rm --no-deps -T tests python - < /tmp/api_data.py 2>/dev/null | tee /tmp/restored-api.txt
echo "== API data identical to source: $(cmp -s /tmp/restored-api.txt /srv/offhost-backups/source-api.txt && echo YES || echo NO)"
echo "== new data flows after restore (publish + verify)"; SPEC=$($C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli publish 3 2>/dev/null | tail -1); $C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli verify "$SPEC" --timeout 60 2>/dev/null | tail -1
echo "== a second restore over the now non-empty database is refused"; /opt/gossy/bin/restore.sh "local:$D" "$TAG" 2>&1 | tail -1; echo "second restore exit=${PIPESTATUS[0]}"
