# E2 - Edge speed

Owner: DK. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

`bollbot.ml.benchmark` on the OAK-D Lite and on the NCNN fallback, 3 runs of about 10 minutes, 416 px.
Success: >= 3 FPS.

## Data in this folder

Per run: `python -m bollbot.ml.benchmark <model> <frames-folder> --n 2000 --out bollbot/experiments/E2/speed_run1.json`
(run2, run3 ...). Every speed*.json in this folder is one run; the KPI is the median.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E2` (or the notebook `E2.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
