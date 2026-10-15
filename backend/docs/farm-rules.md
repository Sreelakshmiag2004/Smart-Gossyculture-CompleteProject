# Farm rules (Phase II, Module 7b)

The backend turns cart scans and entered field data into **advice** for each farm. The rules are
the same code the cart and the experiments use: `src/gossy/farmrules/core` and `config/` are an
exact copy of `bollbot/core` and `bollbot/config/{thresholds,etl}.yaml`. CI fails if the copies
differ; after changing a rule or a threshold in `bollbot/`, run `bash backend/scripts/sync_farm_rules.sh`.

Advice never reaches a device. There is no command path (v1 monitoring-only boundary).

## Inputs

| Input | Where it comes from | Used for |
|---|---|---|
| Segment scans | `event/scan` from the cart (MQTT), via the farm's devices | Readiness per row segment, pink bollworm camera ratios |
| Trap counts | `POST /farms/{id}/traps` (one count per trap and night; re-posting replaces it) | Pink bollworm trap rule (3 nights) |
| Scouting counts | `POST /farms/{id}/observations` (keys: `GET /farm-rules/catalog`) | Whitefly, jassid, thrips, aphid, bollworm, mealybug, leaf curl |
| Checked detections | `POST /farms/{id}/confirmations` (confirmed or rejected) | WHERE to spot-treat mealybug (never WHETHER) |
| Rain forecast | Open-Meteo, fetched hourly by the worker for farms with a location | Rain alert (PICK_NOW), picking window when the cart has no recent reading |

Only the last 14 days are used. Dates are Indian dates; data entry for the future or more than
60 days back is refused.

## Output

* `GET /farms/{id}/status`: readiness per segment (`READY` ≥ 0.40, `BUILDING` ≥ 0.20), picking
  window (`SAFE`/`WAIT` with reasons), current weather and its source, rain in the last 24 h,
  highest rain probability in the next 48 h, and every pest rule with its value, threshold and
  whether the evidence is sufficient.
* `GET /farms/{id}/advisories`: `PICK_NOW`, `PICK_LIST`, `PEST_ETL`, `SPOT_TREAT`, `PEST_ALERT`,
  `SPRAY_BLOCKED`, in English and Tamil. One active advisory per type and pest: it is updated while
  the condition lasts and resolved (kept as history) when it clears.

Safety rules enforced by the engine: a spray-related pest advisory becomes `SPRAY_BLOCKED` while
any segment has R ≥ 0.30 (pick first; pre-harvest interval); mealybug is spot treatment only, and
only on the field-sample threshold; leaf curl virus is an alert (remove plants), never a spray.

## When the rules run

* Right after each data entry (the response reflects it on the next status read).
* `POST /farms/{id}/status/recompute`, for example after a cart pass.
* Every minute for every farm, by the worker `python -m gossy.farmrules` (Compose service
  `farmrules`), which also refreshes the forecast hourly. Without internet, set
  `GOSSY_FARMRULES_WEATHER_ENABLED=false`: the pest rules and readiness still work.

## Who may do what

| Caller | Read status/advice/data | Enter data | Location, operators |
|---|---|---|---|
| Owner | yes | yes | yes |
| Operator (added by the owner by phone number) | yes | yes | no (403) |
| Admin | yes | no (403) | no (403) |
| Anyone else | 404 | 404 | 404 |

Operators do not see the farm's devices or telemetry. Removing an entry or an operator sets a
timestamp: the runtime database role has no DELETE privilege.

## Not done yet

Push notifications (`notified_at` records when an advisory would be pushed); live WebSocket
events for advice (the app reads the endpoints above). Tamil text must be reviewed by a native
speaker and an agriculture officer before the farmer trial (E9).
