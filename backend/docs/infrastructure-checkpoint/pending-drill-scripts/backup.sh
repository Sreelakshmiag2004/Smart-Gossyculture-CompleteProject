set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
export GOSSY_COMPOSE="$C"
cd /opt/gossy
FP() { $C exec -T timescaledb psql -U postgres -d gossy -At < /tmp/fingerprint.sql; }
echo "== SOURCE fingerprint (before backup)"; FP | tee /srv/offhost-backups/source-fingerprint.txt
echo "== SOURCE data served by the API"; $C --profile test run --rm --no-deps -T tests python - < /tmp/api_data.py 2>/dev/null | tee /srv/offhost-backups/source-api.txt
rm -f /srv/offhost-backups/gossy-*.dump*
echo "== backup.sh"; /opt/gossy/bin/backup.sh 2>&1; echo "backup exit=$?"
echo "== off-host destination"; ls -l /srv/offhost-backups | sed 's/^/  /'
D=$(ls /srv/offhost-backups/gossy-*.dump | tail -1); echo "  meta: $(cat "$D.meta.json")"; echo "  sha256: $(cat "$D.sha256")"; (cd /srv/offhost-backups && sha256sum -c "$(basename "$D").sha256")
echo "== backup left on the host data volume? (expect empty tmp dir)"; ls -A /srv/gossy/backups/tmp | wc -l
