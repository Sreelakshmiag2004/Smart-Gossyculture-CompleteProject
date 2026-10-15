# E6 - Pest signals and ETL logic

Owner: SS, DK. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

(a) Rule cases: rule_cases.yaml (36 cases from the published thresholds) run through the real engine.
(b) Camera vs scouting on >= 40 segments: for classes 5-7 (rosette_flower, boll_bored, mealybug_colony),
did the camera report the sign (count > 0), and did the operator find it on the plants?
Success: rule cases 100 % pass; per-class precision/recall reported.

## Data in this folder

`scout_found`: 1 if the operator found the sign in that segment, 0 if not. Scout WITHOUT looking at the camera result.
Never edit rule_cases.yaml to make a case pass: a failing case means the engine or the threshold file is wrong.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E6` (or the notebook `E6.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
