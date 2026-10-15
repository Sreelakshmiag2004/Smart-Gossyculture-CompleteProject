set -a; . /etc/gossy/gossy.env; set +a
C="docker compose --env-file /etc/gossy/gossy.env --env-file /etc/gossy/release.env -f /opt/gossy/compose.yaml $GOSSY_COMPOSE_EXTRA"
export GOSSY_COMPOSE="$C"
cd /opt/gossy
echo "== services"; $C ps -a --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
echo "== api healthz/readyz (loopback)"; curl -fsS http://127.0.0.1:8000/healthz; echo; curl -fsS http://127.0.0.1:8000/readyz; echo
echo "== ingest healthz/readyz (loopback)"; curl -fsS http://127.0.0.1:8001/healthz; echo; curl -fsS http://127.0.0.1:8001/readyz; echo
echo "== database / timescaledb"
$C exec -T timescaledb psql -U postgres -d gossy -Atc "select 'postgres ' || current_setting('server_version'); select 'timescaledb ' || extversion from pg_extension where extname='timescaledb'; select 'alembic ' || version_num from alembic_version; select 'hypertable ' || hypertable_name || ' chunks=' || num_chunks from timescaledb_information.hypertables; select 'password_encryption ' || current_setting('password_encryption'); select 'role ' || rolname || ' super=' || rolsuper || ' createdb=' || rolcreatedb from pg_roles where rolname like 'gossy%' order by 1; select 'app privileges on telemetry: ' || string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants where grantee='gossy_app' and table_name='telemetry'"
echo "== app role cannot DELETE / DDL (expect permission errors)"
$C exec -T timescaledb sh -c 'PGPASSWORD=$(cat /run/gossy-secrets/db/app.password) psql -h 127.0.0.1 -U gossy_app -d gossy -Atc "delete from telemetry" 2>&1 | grep ERROR; PGPASSWORD=$(cat /run/gossy-secrets/db/app.password) psql -h 127.0.0.1 -U gossy_app -d gossy -Atc "create table x(i int)" 2>&1 | grep ERROR; PGPASSWORD=$(cat /run/gossy-secrets/db/app.password) psql -h 127.0.0.1 -U gossy_app -d gossy -Atc "update audit_log set action=action" 2>&1 | grep ERROR'
echo "== limits / restart policy / hardening per container"
for c in $(docker ps --format '{{.Names}}' | sort); do docker inspect "$c" --format '{{.Name}} restart={{.HostConfig.RestartPolicy.Name}} mem={{.HostConfig.Memory}} nanocpus={{.HostConfig.NanoCpus}} readonly={{.HostConfig.ReadonlyRootfs}} capdrop={{.HostConfig.CapDrop}} capadd={{.HostConfig.CapAdd}} secopt={{.HostConfig.SecurityOpt}} user={{.Config.User}} restarts={{.RestartCount}}'; done
echo "== listening sockets on the host (all interfaces vs loopback)"; ss -Htln | awk '{print $4}' | sort -u
echo "== docker API: tcp listeners for dockerd"; ss -Htlnp | grep -i dockerd || echo "none (unix socket only)"
echo "== secrets tmpfs"; mount | grep gossy-secrets; ls -ln /run/gossy-secrets /run/gossy-secrets/app /run/gossy-secrets/db 2>&1 | sed 's/^/  /'
echo "== secrets on persistent disk? (search /srv/gossy, /opt/gossy, /etc for every rendered secret value; pgdata excluded: it stores SCRAM verifiers, checked below)"
find /run/gossy-secrets -type f ! -name .revision -exec cat {} \; -exec echo \; > /run/gossy-secrets/.patterns
HITS=$(find /srv/gossy /opt/gossy /etc -xdev -type f -size -20M ! -path '/srv/gossy/pgdata/*' ! -name rehearsal-secrets.json -print0 | xargs -0 grep -l -F -f /run/gossy-secrets/.patterns 2>/dev/null)
rm -f /run/gossy-secrets/.patterns
if [ -n "$HITS" ]; then echo "$HITS" | sed 's/^/  FOUND: /'; else echo "  none found"; fi
echo "  role password storage: $($C exec -T timescaledb psql -U postgres -Atc "select string_agg(rolname || '=' || left(rolpassword, 13), ' ') from pg_authid where rolname in ('postgres','gossy_owner','gossy_app')")"
echo "  broker password file: $(cut -d: -f2 /srv/gossy/broker/generated/passwd | cut -c1-3 | sort -u | tr '
' ' ') (hash prefixes only)"
echo "== time sync (host clock vs container clocks, seconds)"; date -u +%s; $C exec -T api date -u +%s; $C exec -T timescaledb date -u +%s
