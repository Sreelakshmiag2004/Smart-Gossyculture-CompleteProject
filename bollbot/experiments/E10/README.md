# E10 - Arm demonstrator

Owner: DK. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Bench: 50 picks on cut fruiting branches at field spacing. Field: 20 picks, cart parked. Claw vs vacuum-roller on the same 20 branches.
Success = >= 80 % of the boll's seed cotton removed in one attempt. Cycle time detected -> home. Trash % = non-lint mass in the bin.
Success: >= 60 % (vacuum-roller); cycle time reported next to the 4 s product need; trash <= 10 %.

## Data in this folder

`python -m bollbot.edge.arm.harvest run ... --log bollbot/experiments/E10/picks.csv` writes one row per attempt.
After each attempt the operator fills: outcome, lint_left_g, trash_g, and adds columns `setting` (bench/field),
`effector` (vacuum/claw) and `picked_g` (seed cotton collected).

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E10` (or the notebook `E10.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
