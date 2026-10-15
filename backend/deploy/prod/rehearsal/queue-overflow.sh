#!/usr/bin/env bash
# LOCAL REHEARSAL ONLY (disposable data): broker queue behaviour while the ingest service is
# away (its persistent session keeps queueing).
#
#   run-rehearsal.sh exec <host> 'bash /opt/gossy/rehearsal/queue-overflow.sh [depth] [low-bound]'
#
# Part 1 - throughput vs queue depth, UNCHANGED production broker settings: <depth> QoS 1
#          messages (default 3000) are queued; the time per 500 acknowledgements shows the cost
#          of saving the store after every change (autosave_on_changes, Phase 2.5).
# Part 2 - behaviour AT the bound: max_queued_messages is lowered to <low-bound> (default 500) on
#          this rehearsal host only, so the bound is reached in seconds; what happens at the bound
#          does not depend on its value. Shows which messages are dropped and what the DEVICE is
#          told (PUBACK reason code). The original configuration is restored afterwards (trap).
set -uo pipefail
C=${GOSSY_COMPOSE:?}
DEPTH=${1:-3000}
LOW=${2:-500}
CONF=/opt/gossy/mosquitto/mosquitto.conf
PY="$C --profile test run --rm --no-deps -T tests python -"
SCRIPT=/opt/gossy/rehearsal/queue_overflow.py
LIMIT=$(awk '$1=="max_queued_messages" {print $2}' $CONF)
broker() { echo "memory $(docker stats --no-stream --format '{{.MemUsage}}' gossy-mosquitto-1), store $(du -h /srv/gossy/broker/data/mosquitto.db 2>/dev/null | cut -f1)"; }
metric() { curl -fsS --max-time 5 http://127.0.0.1:8001/metrics 2>/dev/null | awk -v m="$1" '$1==m {print $2}'; }
wait_broker() { for _ in $(seq 1 60); do $C ps mosquitto --format '{{.Status}}' | grep -q '(healthy)' && return 0; sleep 2; done; return 1; }
drain() {  # start ingest, wait until it has received <n> messages (or stops making progress for 60 s)
  local want=$1 t0 last=-1 stable=0 now
  t0=$(date +%s)
  $C start ingest >/dev/null 2>&1
  for _ in $(seq 1 900); do
    now=$(metric gossy_ingest_received_total); now=${now:-0}
    [ "$now" -ge "$want" ] && break
    [ "$now" = "$last" ] && stable=$((stable + 1)) || stable=0
    [ "$stable" -ge 30 ] && break
    last=$now; sleep 2
  done
  echo "ingest received $now message(s) in $(( $(date +%s) - t0 )) s after start"
}
restore_conf() { [ -f $CONF.orig ] && { mv $CONF.orig $CONF; $C restart mosquitto >/dev/null 2>&1; wait_broker; echo "broker configuration restored (max_queued_messages $(awk '$1=="max_queued_messages" {print $2}' $CONF))"; }; }
trap restore_conf EXIT

echo "=== Part 1: throughput vs queue depth (max_queued_messages $LIMIT, autosave_on_changes true - production settings)"
echo "broker before: $(broker)"
$C stop ingest >/dev/null 2>&1
BASE=$(( $(date +%s) * 100000 ))
$PY publish "$BASE" "$DEPTH" 900 < $SCRIPT 2>/dev/null | tail -1
echo "broker with $DEPTH queued: $(broker)"
drain "$DEPTH"
$PY report "$BASE" "$DEPTH" < $SCRIPT 2>/dev/null | tail -1
echo "broker after drain: $(broker)"

echo "=== Part 2: behaviour at the bound (REHEARSAL ONLY: max_queued_messages lowered to $LOW)"
cp $CONF $CONF.orig
sed -i "s/^max_queued_messages .*/max_queued_messages $LOW/" $CONF
$C restart mosquitto >/dev/null 2>&1; wait_broker
for _ in $(seq 1 60); do [ "$(metric gossy_ingest_mqtt_connected)" = 1 ] && break; sleep 2; done   # session re-established
$C stop ingest >/dev/null 2>&1
COUNT=$(( LOW + 300 ))
BASE=$(( $(date +%s) * 100000 ))
$PY publish "$BASE" "$COUNT" 300 < $SCRIPT 2>/dev/null | tail -1
$C logs --since 5m mosquitto 2>/dev/null | grep -i -m 2 -E 'drop|queue|discard' || echo "(broker log: no line about dropped messages)"
drain "$LOW"
sleep 5
$PY report "$BASE" "$COUNT" < $SCRIPT 2>/dev/null | tail -1
echo "queue test finished"
