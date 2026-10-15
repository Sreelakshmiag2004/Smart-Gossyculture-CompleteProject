#!/usr/bin/env bash
# LOCAL REHEARSAL ONLY (disposable data): drive the ingest service through every alert
# condition and record what /metrics reports - the series the CloudWatch alarms evaluate.
#
#   run-rehearsal.sh exec <host> 'bash /opt/gossy/rehearsal/alert-walkthrough.sh'
#
# 1 temporary retry -> 2 prolonged blockage -> recovery   (database really stopped)
# 3 dead letter      (INSERT on telemetry revoked from the app role: a non-transient error)
# 4 permanent block  (INSERT on rejected_messages also revoked) -> grants restored -> recovery
# Grants are always restored (trap). Uses GOSSY_INGEST_RETRY_PROLONGED_AFTER_S from the env.
set -uo pipefail
C=${GOSSY_COMPOSE:?}
RUN="$C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli"
FAIL=0
psql_admin() { $C exec -T timescaledb psql -U postgres -d gossy -v ON_ERROR_STOP=1 -qAtc "$1"; }
restore_grants() { psql_admin "GRANT INSERT ON telemetry, rejected_messages TO gossy_app" >/dev/null 2>&1 || true; }
trap restore_grants EXIT
metrics() { curl -fsS --max-time 8 http://127.0.0.1:8001/metrics 2>/dev/null; }
condition() { metrics | awk -F'[{}" ]+' '/^gossy_ingest_condition\{/ && $NF==1 {print $3}'; }
value() { metrics | awk -v m="$1" '$1==m {print $2}'; }
show() { printf '%s %-34s condition=%-9s database_up=%s retry_s=%s dead_letters=%s blocked=%s\n' "$(date +%T)" "$1" "$(condition)" "$(value gossy_database_up)" "$(value gossy_ingest_retry_duration_seconds)" "$(value gossy_ingest_dead_letters_total)" "$(value gossy_ingest_blocked_total)"; }
expect() { local want=$1 label=$2 timeout=${3:-60}; for _ in $(seq 1 "$timeout"); do [ "$(condition)" = "$want" ] && { show "$label"; return; }; sleep 1; done; show "$label (TIMEOUT, wanted $want)"; FAIL=$((FAIL + 1)); }
publish_bg() { ( $RUN publish "$1" 2>/dev/null | tail -1 > "$2" ) & }

show "baseline"
[ "$(condition)" = ok ] || FAIL=$((FAIL + 1))

echo "--- 1+2: database stopped while a message is in flight"
$C stop timescaledb >/dev/null 2>&1
publish_bg 1 /tmp/aw1.json; wait
expect retrying "temporary retry" 30
expect prolonged "prolonged blockage (>= threshold)" 90
$C start timescaledb >/dev/null 2>&1
expect ok "recovered after database start" 120
$RUN verify "$(cat /tmp/aw1.json)" --timeout 60 2>/dev/null | tail -1 | cut -c1-120

echo "--- 3: dead letter (INSERT on telemetry revoked)"
before=$(value gossy_ingest_dead_letters_total)
psql_admin "REVOKE INSERT ON telemetry FROM gossy_app"
publish_bg 0 /tmp/aw3.json; wait   # pest + spray + 0 telemetry: events are unaffected
$RUN publish 1 2>/dev/null | tail -1 > /tmp/aw3b.json
for _ in $(seq 1 60); do [ "$(value gossy_ingest_dead_letters_total)" != "$before" ] && break; sleep 1; done
show "after dead letter"
[ "$(value gossy_ingest_dead_letters_total)" != "$before" ] || FAIL=$((FAIL + 1))
DL=$(psql_admin "select count(*) from rejected_messages where reason='processing_failed' and received_at > now() - interval '5 minutes'")
echo "dead-letter rows with full payload in the last 5 min: $DL"
[ "$DL" -ge 1 ] || FAIL=$((FAIL + 1))
[ "$(condition)" = ok ] || FAIL=$((FAIL + 1))   # ingestion continues after a dead letter

echo "--- 4: permanent block (dead-letter store also refused)"
psql_admin "REVOKE INSERT ON rejected_messages FROM gossy_app"
$RUN publish 1 2>/dev/null | tail -1 > /tmp/aw4.json
expect blocked "permanent blockage" 90
restore_grants
expect ok "recovered after grants restored" 120
$RUN verify "$(python3 -c 'import json,sys; d=json.load(open("/tmp/aw4.json")); print(json.dumps(d))')" --timeout 60 2>/dev/null | tail -1 | cut -c1-120

echo "alert walkthrough finished: $FAIL problem(s)"
exit $((FAIL > 0))
