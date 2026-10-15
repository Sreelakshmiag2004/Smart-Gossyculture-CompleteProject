#!/usr/bin/env bash
# Phase 2.5 durability scenarios that need Docker control (DEVELOPMENT stack only).
#
#   cd backend && bash scripts/durability_check.sh [D E F F2 G1 G2 ...]   (default: all)
#
# D   database unavailable for 90 s while devices publish (Phase 2 code lost messages here)
# E   database restarted in the middle of a message stream (reconnect)
# F   broker restarted gracefully while ingest holds unacknowledged messages
# F2  broker killed (SIGKILL) while it holds queued messages (broker process crash)
# G1  ingest stopped while devices publish, then started
# G2  ingest SIGKILLed while it holds received-but-unstored messages (Phase 2 code lost 10/10)
#
# Each scenario publishes through MQTT/TLS as device sim-0002 and verifies, per message:
# exactly one ledger row, exactly one telemetry/event row, the exact alert count - no loss and
# no duplicate effects. Nothing in the database is modified by this script.
set -uo pipefail
cd "$(dirname "$0")/.."
# GOSSY_COMPOSE lets the same scenarios run against the production stack rehearsal (Phase 3).
C=${GOSSY_COMPOSE:-docker compose -f deploy/dev/compose.yaml}
RUN="$C --profile test run --rm --no-deps -T tests python -m tests.integration.durability_cli"
SCENARIOS=("$@")
[ $# -eq 0 ] && SCENARIOS=(D E F G1 G2 F2)
FAILED=0

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
wait_db() { for _ in $(seq 1 90); do $C ps timescaledb --format '{{.Status}}' | grep -q '(healthy)' && return 0; sleep 2; done; log "database did not become healthy"; return 1; }
wait_broker() { for _ in $(seq 1 90); do $C ps mosquitto --format '{{.Status}}' | grep -q '(healthy)' && return 0; sleep 2; done; log "broker did not become healthy"; return 1; }
wait_ingest() { for _ in $(seq 1 90); do curl -s http://127.0.0.1:8001/readyz 2>/dev/null | grep -q '"status":"ready"' && return 0; sleep 2; done; log "ingest did not become ready"; return 1; }
publish() { $RUN publish "$@" 2>/dev/null | tail -1; }
verify() {
  local name=$1 spec=$2 out
  out=$($RUN verify "$spec" --timeout 180 2>/dev/null | tail -1)
  log "$name: $out"
  echo "$out" | grep -q '"result": "PASS"' || FAILED=$((FAILED + 1))
}

wait_db && wait_broker && wait_ingest || exit 2

for s in "${SCENARIOS[@]}"; do
  case $s in
  D)
    log "D: stopping database for 90 s while publishing"
    $C stop timescaledb >/dev/null 2>&1
    SPEC=$(publish 20)
    sleep 90
    $C start timescaledb >/dev/null 2>&1; wait_db
    verify D "$SPEC" ;;
  E)
    log "E: restarting database in the middle of a 40-message stream"
    TMP=$(mktemp)
    ( publish 40 --interval 0.25 > "$TMP" ) &
    sleep 4
    $C restart timescaledb >/dev/null 2>&1
    wait; wait_db
    verify E "$(tail -1 "$TMP")"; rm -f "$TMP" ;;
  F)
    log "F: broker restart while ingest holds unacknowledged messages (database stopped)"
    $C stop timescaledb >/dev/null 2>&1
    SPEC=$(publish 10)
    sleep 3
    $C restart mosquitto >/dev/null 2>&1; wait_broker
    $C start timescaledb >/dev/null 2>&1; wait_db; wait_ingest
    verify F "$SPEC" ;;
  F2)
    # Needs autosave_on_changes (deploy/dev/mosquitto/mosquitto.conf). Proves survival of a
    # broker PROCESS kill; host power loss is not covered (Mosquitto does not fsync each save).
    log "F2: broker SIGKILL while it holds queued messages (ingest stopped)"
    $C stop ingest >/dev/null 2>&1
    SPEC=$(publish 10)
    sleep 2
    $C kill -s SIGKILL mosquitto >/dev/null 2>&1
    $C start mosquitto >/dev/null 2>&1; wait_broker
    $C start ingest >/dev/null 2>&1; wait_ingest
    verify F2 "$SPEC" ;;
  G1)
    log "G1: ingest stopped while publishing, then started"
    $C stop ingest >/dev/null 2>&1
    SPEC=$(publish 10)
    $C start ingest >/dev/null 2>&1; wait_ingest
    verify G1 "$SPEC" ;;
  G2)
    log "G2: ingest SIGKILL while holding received-but-unstored messages (database paused)"
    $C pause timescaledb >/dev/null 2>&1
    SPEC=$(publish 10)
    sleep 3
    $C kill -s SIGKILL ingest >/dev/null 2>&1
    $C unpause timescaledb >/dev/null 2>&1; wait_db
    $C start ingest >/dev/null 2>&1; wait_ingest
    verify G2 "$SPEC" ;;
  *) log "unknown scenario $s"; FAILED=$((FAILED + 1)) ;;
  esac
done

log "durability_check finished: $FAILED failed"
exit $((FAILED > 0))
