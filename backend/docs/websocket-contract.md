# WebSocket contract `gossy.ws.v1` — live monitoring (server → app only)

Source of truth in code: `src/gossy/realtime/` (`routes.py`, `events.py`, `hub.py`).
REST contract: `docs/openapi.json`. MQTT contract: `docs/mqtt-contract.md`.

## v1 security boundary

* The channel is **read-only**. The server streams events; the client may only send `start`,
  `resume` and `ping`. Any other operation is answered with `unsupported_op` and has no effect.
* There is **no** path from this channel to a device: the API process contains no MQTT client
  (unit-tested), the broker ACL gives the backend no publish rights, and the MQTT contract has no
  command, config or control topic.

## Endpoint and authentication

| Item | Value |
|---|---|
| URL | `GET /api/v1/ws` (upgrade). Development: `ws://127.0.0.1:8000/api/v1/ws`; deployed environments must use `wss://` behind TLS (U-6) |
| Authentication | `Authorization: Bearer <accessToken>` on the upgrade request (same token as REST) |
| Missing / invalid / revoked token | Handshake refused **before** acceptance (HTTP 403); no frame is sent |
| Authorization | Events are filtered per connection to the devices the user may read (farmer: active devices on farms they own; admin: all registered devices). The device set is re-evaluated every `ws_refresh_s` (default 30 s) |
| Session revoked (logout, refresh-token reuse, user disabled) | Detected within `ws_refresh_s`; server sends `error/session_revoked` and closes with **4401** |
| Access token expires | Server sends `error/token_expired` and closes with **4401**. Client refreshes via `POST /api/v1/auth/refresh`, reconnects and sends `resume` |

## Connection lifecycle

```
client                                   server
  |-- upgrade + Authorization ------------->|  token checked; rejected => 403, no frames
  |<------------------------------ hello ---|  latestCursor, tokenExpiresAt, heartbeatIntervalS
  |-- start  (fresh)  or  resume{cursor} -->|
  |<---- [event ... replayed] + resumed ----|  (resume)  or  resumed{replayed:0} (start)
  |<----------------------- event (live) ---|  one per ingested message, cursor strictly increasing
  |<------------------------- heartbeat ----|  every heartbeatIntervalS (default 25 s)
  |-- ping -------------------------------->|
  |<------------------------------ pong ----|
```

No event is delivered until the client sends `start` or `resume`. `resume` is only accepted
before the stream has started (`already_started` otherwise).

## Reconnect-safe delivery

* Every event carries `cursor` — the server-assigned, strictly increasing ingestion sequence of
  the source message. Cursors are **gap-tolerant** (not contiguous, and filtered per user).
* The client stores the last `cursor` it processed. After any disconnect it reconnects with
  exponential backoff and sends `{"op":"resume","cursor":<last>}`. The server replays every
  permitted event with a greater cursor (up to `ws_replay_limit`, default 1000), then sends
  `resumed` and continues live. Events are never sent twice within one connection.
* If more than `ws_replay_limit` events were missed, the server sends `resync_required`
  (with `latestCursor`) instead: the client reloads state via REST and sends `start`.
* An event is only published after the database transaction that stored it has committed
  (PostgreSQL `NOTIFY` is transactional). A duplicate MQTT delivery produces no event.
* Slow consumer: if a connection's queue (`ws_queue_size`, default 1000) overflows, the server
  closes with **4008** and the client resumes from its last cursor.

## Client → server messages (JSON text frames, ≤ 4096 bytes)

| Message | Meaning |
|---|---|
| `{"op":"start"}` | Begin live delivery from now (no replay) |
| `{"op":"resume","cursor":123}` | Replay events after `cursor`, then continue live. `cursor` must be a non-negative integer |
| `{"op":"ping"}` | Answered with `pong` |

Larger frames close the connection with **1009**. Non-JSON frames get `error/invalid_message`.

## Server → client messages

| `type` | Fields |
|---|---|
| `hello` | `protocol` (`"gossy.ws.v1"`), `serverTime`, `latestCursor`, `tokenExpiresAt`, `heartbeatIntervalS`, `allowedOps` (`["start","resume","ping"]`) |
| `event` | see below |
| `resumed` | `cursor` (last cursor delivered), `replayed` (count) |
| `resync_required` | `latestCursor`, `message` |
| `heartbeat` | `serverTime`, `cursor` (last cursor delivered on this connection) |
| `pong` | `serverTime` |
| `error` | `code`, `message`. Codes: `invalid_message`, `invalid_cursor`, `already_started`, `unsupported_op`, `session_revoked`, `token_expired` |

### `event`

```json
{
  "type": "event",
  "cursor": 4812,
  "kind": "event/pest",
  "deviceId": "sim-0002",
  "msgId": "01K6CQ4W0D8V9J4Q9W2Y1S7ZPX",
  "ts": "2026-09-30T10:15:02.412000+00:00",
  "receivedAt": "2026-09-30T10:15:02.530114+00:00",
  "data": {"label": "bollworm", "confidence": 0.87, "bbox": [0.1, 0.2, 0.1, 0.1]},
  "alerts": [
    {"id": "…", "type": "pest_detected", "severity": "warning", "status": "open",
     "deviceId": "sim-0002", "occurredAt": "…", "createdAt": "…",
     "sourceMsgId": "01K6CQ4W0D8V9J4Q9W2Y1S7ZPX",
     "details": {"label": "bollworm", "confidence": 0.87}, "acknowledgedAt": null}
  ]
}
```

| Field | Rule |
|---|---|
| `kind` | `telemetry`, `event/pest`, `event/spray`, `event/harvest`, `event/scan`, `event/pick`, `status` (the MQTT message kinds) |
| `ts` | device timestamp; `receivedAt` = backend receipt time |
| `data` | the validated MQTT `data` object (camelCase, fields per `docs/mqtt-contract.md`) |
| `alerts` | alerts created from this message (same schema as `GET /api/v1/alerts`); usually empty |

Detections (`event/pest`) are reported by the upstream device detector. The backend performs no
inference and makes no accuracy claim. Moisture values are readings only (U-1 unresolved).

## Close codes

| Code | Reason |
|---|---|
| 1000 | normal |
| 1009 | client frame too large |
| 1011 | internal error |
| 4008 | slow consumer — resume from last cursor |
| 4401 | `session_revoked` or `token_expired` — refresh / sign in, then resume |

## Known limitations

* Tokens are sent in a header, which mobile clients support; browser clients cannot set it
  (not needed in v1: Android app only).
* Cursor ordering relies on a single, sequential ingest writer (Phase 1 limitation L2). Concurrent
  ingest writers would need commit-ordered cursors before this guarantee holds.
* Fan-out uses PostgreSQL LISTEN/NOTIFY inside one API process; several API replicas each run
  their own listener (supported), but rate limits are per process.
