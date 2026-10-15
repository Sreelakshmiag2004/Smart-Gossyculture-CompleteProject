# E3 - Counting accuracy

Owner: DK, SS. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Cart counts and phone-mode counts vs hand counts on 50 plant segments.
Count by hand FIRST, then run the cart; the person counting by hand does not see the cart's numbers.
Scan time: stopwatch on 3 plots.
Success: open-boll MAPE <= 15 % (cart); phone mode reported; scan time <= 60 min/acre.

## Data in this folder

`counts.csv`: one row per segment and class. `true` = hand count, `pred` = system count, `mode` = cart or phone.
`scan_times.csv`: one row per timed plot.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E3` (or the notebook `E3.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
