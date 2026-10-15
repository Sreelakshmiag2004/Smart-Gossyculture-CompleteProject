# E11 - Power

Owner: SL. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

INA219 logging over a full scan day, 2 days. Success: >= 4 h per charge; mean power (Wh per hour) reported.

## Data in this folder

`python -m bollbot.edge.power_log --out bollbot/experiments/E11/power_day1.csv` on the Pi for the whole scan day.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E11` (or the notebook `E11.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
