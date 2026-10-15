# BollBot Scout – software

Software for the BollBot Phase II specification: a cotton harvest-timing and pest-scouting system.

## Build plan (one module at a time)

| # | Module | Folder | Status |
|---|---|---|---|
| 1 | Shared data model + decision engine (readiness, picking window, rain alert, ETL rules, Tamil/English text) | `core/`, `config/` | **Done** |
| 2 | ML pipeline: dataset checks, farm-wise split, training, evaluation, export (OAK-D / NCNN / TFLite) | `ml/` | **Done – 13 tests; training runs on Colab** |
| 3 | Edge cart software: camera + detection, ByteTrack counting, ArUco segments, BME280, SQLite outbox, sync | `edge/` | **Done** |
| 4 | ESP32 firmware + Pi MQTT bridge: pump, safety interlocks, PCA9685 servo driver | `firmware/esp32/`, `edge/` | **Done** |
| 5 | Robotic harvesting: stereo localisation, inverse kinematics, hand-eye calibration, pick state machine | `edge/arm/` | **Done** |
| 6 | Farm rules service (storage-independent) + Open-Meteo forecast; local demo runner | `cloud/` | **Done** (Firebase deployment retired, see 7) |
| 7a | Integration with the team backend: MQTT contract `bollbot/v1` extended (scan, pick); cart publishes to the backend broker | `edge/contract.py`, `edge/sync.py` + backend patch | **Done** |
| 7b | Backend: farm rules (advisories replace alert-per-detection), traps/observations API, forecast job, operator role | backend repo | Next |
| 7c | Flutter app: field map, picking window, scouting entry, Tamil advisories (existing app extended) | app repo | |
| 8 | Experiment analysis notebooks E1–E11 | `experiments/` | |

**Tests: 149 Python + 94 firmware passing** in this repo (41 core, 13 ML, 19 QA regression, 19 cart, 11 actuator link, 20 harvesting, 13 farm rules, 13 contract/uploader), plus **100 backend contract checks** run against the team backend's own validation code. QA report of 14 Oct 2026: all 16 bugs fixed.

## Module 1 – what is here

| File | Purpose |
|---|---|
| `config/thresholds.yaml` | Readiness bands, picking-window rule, rain alert, spray block, moisture classes. All marked (A) values are tuned in experiment E4. |
| `config/etl.yaml` | Pest economic thresholds, **checked 14 Oct 2026** against the AESA-based IPM package for cotton (DPPQ&S / NCIPM, 2014), ICAR-CICR PBW strategy (2019) and the ICAR-CICR mealybug package (Nagrare et al., 2011); source cited per value. `strict: true` = 'more than'. Adopted as published (14 Oct 2026); not externally confirmed. |
| `core/models.py` | `SegmentScan`, `TrapCount`, `ManualObservation`, `ConfirmedDetection`, `Advisory`; JSON matches spec Section 11. The 8 class names are fixed here, in model index order. |
| `core/rules.py` | Readiness R, dew point (Magnus), picking window, rain alert, pick list, spray block, oven-dry moisture helpers. |
| `core/etl.py` | ETL evaluators: trap nights, camera ratio, per-leaf mean, % plants, presence. Returns "insufficient" instead of guessing on small samples. |
| `core/messages.py` | Tamil + English advisory templates. **Tamil must be reviewed by a native speaker before E9.** |
| `core/engine.py` | `run_farm()` – runs everything for one farm and returns the advisories to publish. |
| `tests/test_core.py` | 41 unit tests. `tests/test_qa_fixes.py`: 19 regression tests, one per QA bug. |

### Safety rules enforced in code

- Mealybug spot treatment needs the field sampling threshold (≥ 10% of ≥ 40 sampled plants at grade 2); camera or confirmed detections only say *where*, never *whether*.
- Any **spray-related** pest advisory becomes `SPRAY_BLOCKED` while a segment has R ≥ 0.30, so spraying and picking never overlap. Leaf-curl alerts stay `PEST_ALERT`: their advice is to remove plants, not to spray, so there is no pre-harvest-interval conflict.
- Leaf curl virus is always `PEST_ALERT` (rogue plants), never a spray advice.

## Module 2 – ML pipeline

| File | Purpose | Needs Ultralytics? |
|---|---|---|
| `config/ml.yaml` | Model, image size, epochs, targets (mAP@50 ≥ 0.80, open-boll recall ≥ 0.85, ≥ 3 FPS, counting MAPE ≤ 15%), rare-class rule | – |
| `ml/LABELLING.md` | Labelling guide: 8 classes, rules, double-labelling | – |
| `ml/dataset.py` | Validates `raw/<FARM>/{images,labels}`: label format, class range, orphans, tiny/duplicate boxes, cross-farm duplicate images; per-farm class counts | No |
| `ml/split.py` | Farm-wise train/val/test split, writes `data.yaml` + `manifest.json`; refuses leakage; public data goes to train only | No |
| `ml/metrics.py` | Target check, rare classes, confusion matrix, counting MAE/MAPE (E3), speed (E2) | No |
| `ml/train.py` | Trains YOLOv8n; writes `run_meta.json` (dataset hash, settings, versions) | Yes |
| `ml/evaluate.py` | Test-farm metrics → `eval_test.json` with per-class P/R/mAP, confusion matrix, targets met/missed | Yes |
| `ml/export.py` | NCNN, TFLite int8, OpenVINO; OAK-D via tools.luxonis.com | Yes |
| `ml/benchmark.py` | On-device FPS and latency (E2) | Yes |
| `ml/train_colab.ipynb` | Runs steps 1–5 on a free Colab GPU | – |
| `experiments/E3/counts_template.csv` | Format for hand-count vs model-count data | – |

Typical workflow:

```bash
python -m bollbot.ml.dataset raw/                                   # 0 errors required
python -m bollbot.ml.split raw/ dataset/ --train F01 F02 --val F03 --test F04   # --overwrite to redo
python -m bollbot.ml.train dataset/data.yaml --name v1              # GPU / Colab
python -m bollbot.ml.evaluate runs/v1/weights/best.pt dataset/data.yaml
python -m bollbot.ml.export runs/v1/weights/best.pt dataset/data.yaml
```

### Dates and times

Pass **all** datetimes to `run_farm()` as timezone-aware, or **all** naive in Indian local time; a mix is refused. Aware times are converted to IST for the picking-window hour, and trap/scouting dates are compared with the IST calendar day. Data dated after `now` is ignored, so past days can be replayed for experiments.

## Module 3 – cart software

| File | Purpose | Tested here? |
|---|---|---|
| `config/cart.yaml` | Cart ID, farm, detector, marker, counting, evidence, outbox, sync settings | – |
| `config/markers.csv` | Row-marker table: `tag_id,farm,row,segment` (edit per farm) | – |
| `edge/markers.py` | Loads/validates the marker table; reads ArUco tags; prints laminate-ready tag sheets | Yes, real OpenCV |
| `edge/segments.py` | Current row segment from confirmed tag sightings (a single false sighting cannot split a segment) | Yes |
| `edge/counting.py` | Counts each tracked boll once per pass, in its majority class; drops one-frame noise; never double-counts a boll that spans two segments | Yes |
| `edge/store.py` | SQLite outbox: write first, upload later; safe retries; survives power loss | Yes |
| `edge/sync.py` | Uploads in order with backoff 5 s → 5 min to the backend broker (Module 7a) | Logic yes; broker on hardware |
| `edge/sensors.py` | BME280 weather; falls back to "no weather" with a warning if the sensor is missing | Fallback yes; sensor on hardware |
| `edge/detectors.py` | Ultralytics + ByteTrack (USB camera / video replay / NCNN) and OAK-D Lite (YOLO + depth + tracker on the camera) | On hardware only |
| `edge/cart.py` | The cart program: per-frame loop, scan records, evidence photos, heartbeat, Ctrl-C safe stop | Logic yes (incl. real ArUco frames) |

### Running the cart

```bash
# 1. Print the row markers (laminate, >= 10 cm wide, one per stake)
python -m bollbot.edge.markers sheet --csv bollbot/config/markers.csv --out markers/

# 2. Replay a recorded walk on a laptop (no hardware needed)
python -m bollbot.edge.cart --farm F01 --source walk.mp4 --no-sync

# 3. Live on the Pi (USB camera 0, uploads when online)
python -m bollbot.edge.cart --farm F01
```

Records go to `data/outbox.sqlite` first, and evidence photos to `data/evidence/`. Uploads go to the team backend's broker (Module 7a). Without broker settings, the cart runs offline and keeps everything in the outbox.

### Raspberry Pi setup (once)

1. Flash **Raspberry Pi OS 64-bit**, then enable I²C (`sudo raspi-config` → Interface Options → I2C).
2. Run `pip install -r bollbot/requirements-edge.txt` inside a virtual environment. For the OAK-D Lite, install `"depthai<3"` instead of ultralytics.
3. Check the BME280 with `i2cdetect -y 1`; it shows `76` or `77`. Set `weather.address` to match.
4. Copy the model: `best_ncnn_model/` (USB camera) or the `.blob` + `.json` from tools.luxonis.com (OAK-D) into `bollbot/models/`.

**Not yet verified on hardware:** the OAK-D pipeline (written for the DepthAI v2 API) and the BME280 and the TLS connection to the backend broker. Test each on the Pi before the first field day.

## Module 4 – ESP32 firmware and Pi link

The ESP32 is the **safety authority**. It runs the pump only while the E-stop is released, the dead-man button is held, the MQTT link is up, the ultrasonic readings are fresh and nobody is within 2 m. If any of these fails mid-spray, the pump stops at once and the spray is reported as aborted, with the actual time it ran.

| File | Purpose | Tested here? |
|---|---|---|
| `firmware/esp32/bollbot_fw/core.h/.cpp` | Safety gate, spray controller (incl. millis() wrap-around), servo planner (rejects out-of-limit targets, speed-limited motion), pulse maths | Yes: 45 checks, g++ with sanitizers |
| `firmware/esp32/bollbot_fw/bollbot_fw.ino` | Pins, ultrasonic reads, Wi-Fi/MQTT, JSON commands, status at 1 Hz | Yes: the **real sketch** runs on a PC against stand-in libraries and the real ArduinoJson 7.2.1 (26 checks) |
| `firmware/esp32/bollbot_fw/config.h` | Pin map, timing, spray limits, **arm joint limits (measure yours!)** | – |
| `firmware/esp32/platformio.ini` | Build/upload with PlatformIO (or use the Arduino IDE) | Build on your laptop |
| `firmware/esp32/test/run_tests.sh` | Runs both firmware test suites | – |
| `firmware/mosquitto/bollbot.conf` | MQTT broker config for the Pi (password required) | – |
| `edge/actuators.py` | Pi bridge: dose (ml) → pump time from calibrated flow, readiness pre-check, spray log to outbox, blocking arm moves; CLI for status / calibrate / test spray / home | Yes, with a fake ESP32 |

### Wiring (ESP32 DevKit V1)

| ESP32 pin | Connects to | Note |
|---|---|---|
| GPIO26 | Pump MOSFET gate (or relay IN) | 10 kΩ pull-down gate → GND |
| GPIO32 | Dead-man button → GND | Held = LOW |
| GPIO33 | E-stop **NC auxiliary** contact → GND | The E-stop's main contact also cuts the 12 V pump/servo supply |
| GPIO18 / GPIO19 | Front HC-SR04 TRIG / ECHO | ECHO via 1 kΩ / 2 kΩ divider (5 V → 3.3 V). Faces along the row |
| GPIO16 / GPIO17 | Side HC-SR04 TRIG / ECHO | Same divider. Faces the path, **not** the target plant |
| GPIO21 / GPIO22 | PCA9685 SDA / SCL | Servo power from a separate 5–6 V supply, common GND |
| GPIO4 | PCA9685 OE | HIGH = all servo outputs off |

### First power-up checklist

1. Run `firmware/esp32/test/run_tests.sh` on your laptop. It must end with `firmware tests OK`.
2. Measure each arm joint's safe range by hand and edit `kJoints` in `config.h`.
3. Copy `secrets.example.h` to `secrets.h`, fill it in, then build and upload with PlatformIO.
4. Set up Mosquitto on the Pi (`firmware/mosquitto/bollbot.conf`), and put the Pi's MQTT password in `secrets/mqtt_password`.
5. Run `python -m bollbot.edge.actuators status`. Check `"online": true` and that `block` changes when you press the E-stop or release the dead-man.
6. Put the arm in its home pose by hand, then run `python -m bollbot.edge.actuators home`.
7. **With water only**, run `python -m bollbot.edge.actuators calibrate`. Measure the water, then set `flow_ml_per_s` in `cart.yaml`.

## Module 5 – robotic harvesting

The cart parks beside a row segment. The OAK-D Lite finds open bolls and measures their 3D positions; the calibration converts them into arm coordinates. The arm then picks them one at a time, nearest first:

1. Move to a point 4 cm in front of the boll.
2. Switch the picking head on.
3. Slowly reach the boll surface.
4. Hold for 2 s.
5. Retract.
6. Switch the head off.

The operator holds the dead-man button throughout. Letting go freezes the arm in place and stops the head.

| File | Purpose | Tested here? |
|---|---|---|
| `config/arm.yaml` | Link lengths, servo↔joint mapping, pick settings, calibration poses. **Measure every (A) value** | – |
| `edge/arm/kinematics.py` | Forward/inverse kinematics (4-DOF; also parallel-linkage arms); searches approach angles near the preferred one; rejects targets outside joint limits | Yes: 300-pose round trips, limits, reach |
| `edge/arm/handeye.py` | Camera → arm calibration from point pairs (Kabsch/SVD) with RMS error; refuses rotation-free nonsense and mirrored axes; OAK-D tag locator using the camera's own spatial calculator | Fit yes; OAK-D on hardware |
| `edge/arm/picker.py` | Pick planning (pre-point + contact on one straight approach), the pick cycle with guaranteed head-off on any failure, target selection, E10 attempt log (CSV + outbox) | Yes, with a fake arm |
| `edge/arm/harvest.py` | CLI: `workspace` (pickable zone map), `plan` (no motion), `goto` (E5 touch test), `run` (picking session with operator scoring) | Session logic yes |
| Firmware additions | Picking-head outputs (GPIO25 blower, GPIO27 rollers) with 10 s auto-off; arm and head now also require the dead-man button | Yes (whole-sketch tests) |

### Where the arm can pick

With the placeholder geometry in `arm.yaml`, bolls are pickable only about **27–39 cm in front of the arm base**. The elbow's ±80° range is what limits it. After measuring your arm, run:

```bash
python -m bollbot.edge.arm.harvest workspace
```

Park the cart so the row's open bolls fall in the `#` zone. If the zone is too small, widen the joint limits (only if the arm physically allows it, and in both `arm.yaml` and `config.h`; a test checks they match) or mount the arm closer to the row.

### Harvesting procedure

1. Measure link lengths and zero angles, and fill in `config/arm.yaml` and `config.h`.
2. Calibrate: stick a 2 cm ArUco tag (DICT_4X4_50, id 0) on the nozzle mouth, then run `python -m bollbot.edge.arm.handeye collect`. The RMS must be ≤ 10 mm.
3. E5 touch test: `python -m bollbot.edge.arm.harvest goto --base 0.33 0 0.15` for each pegboard point. Measure the miss distance with a ruler.
4. Dry run: `python -m bollbot.edge.arm.harvest plan` shows targets and plans with no motion.
5. Pick: `python -m bollbot.edge.arm.harvest run --segment R003-S02 --max-picks 10 --confirm`. Score each attempt; the results go to `experiments/E10/picks.csv`.

**Not yet verified on hardware:** the OAK-D tag locator and the real arm geometry. Calibrate and run the E5 touch test before any picking.

**Also fixed in this module:** a pick attempt record would have **blocked all cloud uploads forever**, because the uploader had no collection for it and uploads go strictly in order. It now has one, and any record that can never upload is set aside as a "dead letter" instead of blocking the queue.

## Module 6 – farm rules service

`cloud/service.py` recomputes one farm. It loads 14 days of scans, traps, observations and confirmations; picks the weather; runs the decision engine; reconciles advisories; and builds Tamil/English push messages. All storage goes through a small `Repo` interface: tests use an in-memory one, `cloud/local.py` uses the cart's outbox, and the backend (7b) uses PostgreSQL. `cloud/weather.py` fetches the Open-Meteo forecast.

**Advisory rules (no notification spam):**
- One advisory per farm, type and pest. It is updated while the condition lasts and closed when it clears.
- A push goes out when an advisory first appears.
- "Pick now" re-notifies at most once every 12 hours.
- Unchanged advisories are not rewritten.

The Firebase deployment from the first version of this module was **retired**: the team's own backend (FastAPI, PostgreSQL/TimescaleDB, Mosquitto, OTP login, live WebSocket) is the cloud.

Demo without any server:

```bash
python -m bollbot.cloud.local --outbox bollbot/data/outbox.sqlite --farm F01 --lat 11.23 --lon 78.88
```

## Module 7a – connecting the cart to the team backend

The cart now uploads to the backend's broker using the backend's MQTT contract (`backend/docs/mqtt-contract.md`). The contract was extended **backwards-compatibly**:

| Change | Why |
|---|---|
| New `event/scan`: row, segment, counts for the 8 classes, frames, model, air weather | Readiness maps, pick lists, pest ratios, E3 |
| New `event/pick`: one pick attempt with result, timing and operator score | E10 |
| `event/spray` gains `completed`, `reason`, dose (ml), `purpose`, row/segment; 0 ms allowed only when the spray did not run | E7 needs refused and aborted sprays too |
| Telemetry: `batteryPct` optional, but at least one reading is required; new `airRhPct`, `dewpointC`, `fps`, `outboxPending` | A missing sensor is omitted, never faked; air humidity is weather, **not** boll moisture (resolves the backend's open item U-1) |

**Cart side** (`edge/contract.py`, `edge/store.py`, `edge/sync.py`):
- Every outbox record gets its ULID `msgId` and `seq` when it is queued. Retries re-send the **same** `msgId`, so the backend's exactly-once ingestion works as designed. Older outbox files are upgraded automatically.
- `MqttCloudUploader` connects as the device (MQTT 5 over TLS, username = `cart_id`) and publishes with QoS 1. A record counts as sent only after the broker's PUBACK.
- Online/offline status is published on connect and as the Last Will, never through the outbox (a contract rule).
- A record the contract cannot express is set aside, so it does not block the queue.
- Evidence photos stay on the cart's SD card; the contract reserves image upload for a later phase.

**Proven across both repositories:** `tools/export_contract_samples.py` builds messages with the real cart code. The backend's new test `tests/unit/test_cart_samples.py` runs them through its full ingestion validation. All pass.

Cart setup: in `config/cart.yaml`, set `sync.broker_host`, and put the broker CA at `secrets/broker-ca.crt` and the device password at `secrets/device_password`. Register the cart in the backend as device `cart01`, as you would any device.

## Run the tests

Requires Python 3.10+, PyYAML and Pillow (`pip install pyyaml pillow`). From the folder that **contains** `bollbot/`:

On Windows, set UTF-8 output first, or printing Tamil text fails with a `charmap` error:

```bash
set PYTHONIOENCODING=utf-8        # Windows cmd   (PowerShell: $env:PYTHONIOENCODING="utf-8")
python -m unittest discover -s bollbot/tests -t .
# or, with pytest installed:
pytest bollbot/tests
```

## Quick use

```python
from datetime import datetime, timedelta
from bollbot.core.config import load_thresholds, load_etl
from bollbot.core.engine import run_farm
from bollbot.core.models import SegmentScan

now = datetime(2027, 1, 18, 11, 0)
scan = SegmentScan(farm="F03", row=12, segment=4, ts=now, model="yolov8n-416-v1",
                   counts={"boll_closed": 10, "boll_cracking": 2, "boll_open": 20})
report = run_farm("F03", now, load_thresholds(), load_etl(), scans=[scan],
                  forecast=[(now + timedelta(hours=12), 75.0)])
for a in report.advisories:
    print(a.type.value, a.text_en)
```
