# E8 - IoT reliability

Owner: SL. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Cart (or `bollbot.tools.demo_scans` in load mode) sends continuously; the network is cut for 2 h, then restored (4G in the field).
Every message is reconciled by its msgId: cart outbox vs backend ingestion ledger.
Success: 0 messages lost; median sync latency <= 10 s while online; >= 1,000 messages.

## Data in this folder

1. Load: `python -m bollbot.tools.demo_scans --outbox e8_outbox.sqlite --repeat 400 --every 20 --timeout 600 --password-file ... --ca ...`
   (or the real cart). Cut the network (unplug, airplane mode) for 2 h in the middle; note the times in session.yaml.
2. When it reports `pending 0`: copy the outbox file here as `outbox.sqlite`.
3. Export the backend ledger (Git Bash, from backend/):
   `docker compose -f deploy/dev/compose.yaml exec -T timescaledb psql -U postgres -d gossy -c "\copy (SELECT msg_id, received_at FROM ingested_messages WHERE device_id = 'cart01') TO STDOUT WITH CSV HEADER" > ../bollbot/experiments/E8/backend_messages.csv`
Heartbeats are excluded: the outbox keeps only the latest one by design.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E8` (or the notebook `E8.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
