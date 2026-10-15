# MQTT contract `bollbot/v1` — device → backend (ingestion only)

Source of truth in code: `src/gossy/contracts/` (topics + typed Pydantic models).
Transport: MQTT 5 over TLS (port 8883), QoS 1. One broker credential per device; the broker
username **is** the `deviceId`.

## v1 security boundary

* All v1 topics are **device → backend**. There are **no** command, config or control topics.
* The backend ingest account (`svc-ingest`) has **read-only** broker ACL rights. The broker
  rejects any publish from it (`Not authorized`, reason code 135) — verified by integration tests.
* Devices can publish only to their own topics and receive nothing. (Mosquitto acknowledges a
  wildcard SUBSCRIBE but enforces read permission per message at delivery; the integration
  test proves a device receives zero messages while a read-authorised control client does.)

## Topics

| Topic | Kind | Retained | Schema id |
|---|---|---|---|
| `bollbot/v1/{deviceId}/telemetry` | periodic readings | no | `bollbot.telemetry/1` |
| `bollbot/v1/{deviceId}/event/pest` | pest/disease detection | no | `bollbot.event.pest/1` |
| `bollbot/v1/{deviceId}/event/spray` | spray action log | no | `bollbot.event.spray/1` |
| `bollbot/v1/{deviceId}/event/harvest` | harvest observation (Phase I form, kept for compatibility) | no | `bollbot.event.harvest/1` |
| `bollbot/v1/{deviceId}/event/scan` | counts for one row segment (Phase II) | no | `bollbot.event.scan/1` |
| `bollbot/v1/{deviceId}/event/pick` | one robotic pick attempt (Phase II, E10) | no | `bollbot.event.pick/1` |
| `bollbot/v1/{deviceId}/status` | online / offline (Last Will) | **yes** | `bollbot.status/1` |

`deviceId`: `^[a-z0-9][a-z0-9-]{2,63}$` and must **not** start with `svc-` (reserved for
backend service accounts; checked separately because Pydantic's regex engine has no look-ahead).
The simulator only uses `sim-*` IDs. Image upload (`event/image`) is
reserved for the object-storage phase and is **not** part of v1-Phase 1.

## Envelope (all kinds)

```json
{
  "schema": "bollbot.telemetry/1",
  "msgId": "01K6CQ4W0D8V9J4Q9W2Y1S7ZPX",
  "deviceId": "sim-0001",
  "seq": 42,
  "ts": "2026-09-29T10:15:02.412+00:00",
  "data": { }
}
```

| Field | Rule |
|---|---|
| `schema` | must equal the schema id of the topic kind |
| `msgId` | ULID; **idempotency key** — a redelivered or replayed message is stored once |
| `deviceId` | must equal the `deviceId` in the topic |
| `seq` | per-device counter, ≥ 0 (for gap detection) |
| `ts` | RFC 3339 with timezone (naive timestamps rejected); ≤ 5 min in the future |

Validation is strict (no type coercion). Unknown envelope keys are rejected; unknown keys
inside `data` are ignored (forward compatibility). Max payload 64 KiB. Rejected messages are
logged and written to `rejected_messages` with a reason code.

## `data` per kind — every field traced to a source

| Kind | Field | Type / range | Required | Source |
|---|---|---|---|---|
| telemetry | `batteryPct` | 0–100 | no (since Phase II) | Paper §III.B "battery levels". Omitted when the device has no battery monitor. A telemetry message must contain **at least one** reading |
| telemetry | `moistureRhPct` | 0–100 %RH | no | Paper §V.A (DHT11/DHT22). Stored as a reading only; agronomic meaning is **U-1 (unresolved)** |
| telemetry | `airTempC` | −40–85 | no | PPT module 5 temperature sensor (DHT22 range) |
| telemetry | `bollsHarvestedTotal` | int ≥ 0 | no | Paper §III.B "harvested boll counts" |
| telemetry | `solarActive` | bool | no | PPT module 6 power monitoring; existing dashboard "Solar Active" |
| telemetry | `airRhPct` | 0–100 %RH | no | Phase II: **air** humidity from the cart's BME280, weather for the picking-window rule. Resolves U-1: `moistureRhPct` is not used for harvesting decisions |
| telemetry | `dewpointC` | −40–60 | no | Phase II: dew point from the same sensor |
| telemetry | `fps`, `outboxPending` | 0–1000; int ≥ 0 | no | Phase II cart health (camera frame rate; records not yet acknowledged by the broker). Stored in the ingestion ledger only |
| event/pest | `label` | `^[a-z0-9][a-z0-9_-]*$`, ≤ 64 | yes | Paper §III.B class names (e.g. `bollworm`, `leaf_curl_virus`) |
| event/pest | `confidence` | 0–1 | yes | Paper §III.B confidence values |
| event/pest | `bbox` | `[x, y, w, h]`, each 0–1 | no | Paper §III.B bounding boxes |
| event/spray | `durationMs` | 1–60000 | yes | PPT module 4 (1–2 s bursts). Bound is a validation sanity limit only; burst limits belong to device firmware |
| event/spray | `relatedMsgId` | ULID | no | PPT module 4 "log the event" (links spray to its detection) |
| event/spray | `completed` | bool | no | Phase II E7. `false` = refused or aborted by the firmware's safety gate; only then may `durationMs` be 0 |
| event/spray | `reason` | string ≤ 64 | no | Firmware block reason, e.g. `deadman_released`, `person_side` |
| event/spray | `mlRequested`, `mlDelivered` | 0–10000 | no | Dose at label dilution (from the calibrated pump flow) |
| event/spray | `purpose` | string ≤ 32 | no | e.g. `mealybug_spot`, `calibration`, `manual_test` |
| event/spray | `row`, `segment` | int ≥ 1 | no | Row segment of the target |
| event/scan | `row`, `segment` | int 1–10000 | yes | Row-marker table on the cart (Phase II spec §7) |
| event/scan | `counts` | object of 8 counts, each 0–100000; missing classes = 0 | yes | Detector classes, Phase II spec §6: `bollClosed`, `bollCracking`, `bollOpen`, `bollDefective`, `flower`, `rosetteFlower`, `bollBored`, `mealybugColony`. Each tracked object counted once per pass |
| event/scan | `startedAt` | RFC 3339 with timezone | yes | Segment entry time (`ts` = segment exit time) |
| event/scan | `frames` | int ≥ 0 | yes | Frames processed in the segment |
| event/scan | `model` | string 1–64 | yes | Detector version, for traceability to the evaluation run |
| event/scan | `airTempC`, `airRhPct`, `dewpointC` | as telemetry | no | Weather at the segment |
| event/pick | `attemptId` | `^[a-z0-9-]+$`, ≤ 32 | yes | Cart's attempt id (joins the E10 CSV) |
| event/pick | `result` | `completed` \| `unreachable` \| `aborted` | yes | Pick cycle outcome, Phase II spec §10 |
| event/pick | `reason`, `row`, `segment`, `trackId`, `confidence`, `pitchDeg`, `cycleS` | see `src/gossy/contracts/messages.py` | no | Attempt details |
| event/pick | `outcome`, `lintLeftG`, `trashG` | `picked` \| `partial` \| `missed` \| `damaged`; grams | no | Operator's score of the attempt (E10) |
| event/harvest | `maturity` | `mature` \| `immature` \| `partial` | yes | PPT: Mature / Immature / Partial |
| event/harvest | `picked` | bool | yes | Paper §III.B harvest cycle |
| event/harvest | `moistureRhPct` | 0–100 | no | Paper §V.A |
| status | `state` | `online` \| `offline` | yes | Phase 0 (retained status + Last Will) |

## Reporting interval and freshness (Phase 5A)

* **Reporting interval: a device publishes one `telemetry` message every 60 seconds.** Events
  (`event/*`) and `status` are published when they happen and are not tied to the interval.
  MQTT keep-alive (30-40 s) is separate: it is what lets the broker publish the Last Will.
* **Freshness is measured from backend receipt time, never from the device timestamp `ts`.**
  A telemetry reading is no longer *current* when the backend has received no telemetry from
  the device for **180 seconds** (three reporting intervals), even while the device's status is
  `online` (a device that is connected but has stopped reporting). A wrong device clock
  therefore cannot make an old reading look current, or a current one look old.
* The backend gives both values to clients with every device (`GET /api/v1/devices`:
  `telemetryIntervalS`, `telemetryStaleAfterS`; settings `GOSSY_API_TELEMETRY_INTERVAL_S`,
  `GOSSY_API_TELEMETRY_STALE_AFTER_S`) and the receipt time with every reading
  (`GET /api/v1/devices/{id}/telemetry`: `receivedAt`; live event: `receivedAt`). Clients must
  not hard-code the numbers, and compare against the server's clock (`serverTime` of the live
  channel), not their own.
* A reading whose sensor could not be read is **omitted** from `data`. A device never sends a
  placeholder (0, -1, the previous value) for a reading it does not have.
* The development simulator reports every 5 seconds in `deploy/dev/compose.yaml` so that tests
  stay fast; its own default (`python -m gossy_sim`) is the contract's 60 seconds, and
  `--silent-after N` simulates a device that stays online but stops reporting.

## Delivery guarantees (Phase 2.5)

* **Device → broker:** QoS 1. A device may delete a message from its local queue only after the
  broker's PUBACK. The broker saves its store after every change (`autosave_on_changes`), so a
  broker process crash does not lose acknowledged messages (host power loss: not covered).
* **Broker → ingest:** QoS 1, persistent session (`clean_start=false`, session expiry 1 h, fixed
  client id). The ingest service sends PUBACK **only after** the message's outcome is committed
  in the database (manual acknowledgement). Anything not acknowledged is redelivered after a
  reconnect or restart.
* **Effects are exactly-once, delivery is at-least-once.** `msgId` is the idempotency key: a
  redelivered or re-sent message is recognised in the ledger and produces no second telemetry
  row, event, detection, alert or live WebSocket event. Messages with identical content but
  different `msgId`s are distinct observations and are all stored.
* **Database outage:** ingestion pauses and retries without limit; messages stay with the broker
  (bounded by `max_queued_messages`). A valid message that fails for a non-transient reason is
  dead-lettered with its full payload in `rejected_messages` (`reason = processing_failed`).
* **Ordering:** messages are stored by device timestamp `ts`; late or reordered delivery (e.g.
  offline replay) is accepted, `seq` is recorded but never used for deduplication.

Status is ordered by backend receipt time (a Last Will is built at connect time and therefore
carries an older device timestamp than the subsequent `online`). Devices must not place status
messages in their offline replay queue.
