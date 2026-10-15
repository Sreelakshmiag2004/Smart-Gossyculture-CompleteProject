# E4 - Picking-window rule vs oven-dry moisture

Owner: SS. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Each session: 3 open bolls per sampled segment, pooled (about 15 g), sealed in a zip bag.
Record date, time, segment and the four rule inputs (air temperature, RH, rain in the last 24 h) AT SAMPLING.
Weigh wet within 2 h (0.01 g scale); dry at 105 C to constant mass (change < 0.05 g per hour); weigh dry.
90 samples: 3 time slots x 15 days x 2 farms. Rows in COLLECTION ORDER: the first 45 tune the thresholds, the last 45 test.
Success: >= 85 % agreement (rule SAFE/WAIT vs oven <= 8 % / > 8 %) on the test half; kappa reported.

## Data in this folder

`date` like 2026-11-03, `time` like 10:30 (Indian time). `rain_24h_mm` from the app's farm status (Open-Meteo)
or a rain gauge. Do not change config/thresholds.yaml during the experiment: the analysis tunes on the first half itself.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E4` (or the notebook `E4.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
