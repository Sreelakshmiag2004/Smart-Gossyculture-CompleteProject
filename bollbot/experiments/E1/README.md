# E1 - Detector quality

Owner: DK. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Train on Farms A+B, validate on C, test on held-out Farm D (`bollbot.ml.split` keeps farms apart).
At least 1,500 images and 300 instances for each of classes 0-4.
Success: mAP@50 >= 0.80 and open-boll recall >= 0.85 on Farm D.

## Data in this folder

1. `python -m bollbot.ml.evaluate runs/<name>/weights/best.pt dataset/data.yaml` (test split).
2. Copy `runs/<name>/eval_test.json` and `dataset/manifest.json` into this folder.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E1` (or the notebook `E1.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
