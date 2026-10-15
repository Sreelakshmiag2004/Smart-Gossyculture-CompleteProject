set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
cd /opt/gossy
echo "== structured logs: JSON lines per service (last 400 lines each)"
for s in api ingest caddy timescaledb mosquitto; do
  $C logs --no-log-prefix --tail 400 $s 2>/dev/null | python3 /tmp/logsummary.py $s shape
done
echo "== sample application log lines"
$C logs --no-log-prefix --tail 2000 ingest 2>/dev/null | grep -m 1 'mqtt_connected' | cut -c1-300
$C logs --no-log-prefix --tail 400 api 2>/dev/null | grep -m 1 '"path"' | cut -c1-300
echo "== ingest log events by level/name (whole log: retries, blockage, dead letters are visible)"
$C logs --no-log-prefix ingest 2>/dev/null | python3 /tmp/logsummary.py ingest events
echo "== secrets in logs? (every rendered secret value >= 16 chars searched in all container logs)"
find /run/gossy-secrets -type f ! -name '.*' -exec cat {} \; -exec echo \; | grep -E '^.{16,}$' | sort -u > /run/gossy-secrets/.patterns
for c in $(docker ps -a --format '{{.Names}}'); do docker logs "$c" 2>&1; done > /run/gossy-secrets/.alllogs
echo "  log lines searched: $(wc -l < /run/gossy-secrets/.alllogs); lines containing a secret value: $(grep -c -F -f /run/gossy-secrets/.patterns /run/gossy-secrets/.alllogs)"
echo "  lines containing a bearer token: $(grep -c -i -E 'bearer [a-z0-9_.-]{20,}' /run/gossy-secrets/.alllogs); lines containing a full +999 test phone number: $(grep -c -E '\+999[0-9]{8}' /run/gossy-secrets/.alllogs)"
rm -f /run/gossy-secrets/.patterns /run/gossy-secrets/.alllogs
echo "== resource utilisation vs limits"
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' | sort -r
echo "== data volume usage"; du -sh /srv/gossy/pgdata /srv/gossy/broker /srv/gossy/caddy 2>/dev/null
echo "== restart counts / OOM kills / health"
for c in $(docker ps --format '{{.Names}}' | sort); do docker inspect "$c" --format '{{.Name}} restarts={{.RestartCount}} oomkilled={{.State.OOMKilled}} health={{.State.Health.Status}}'; done
