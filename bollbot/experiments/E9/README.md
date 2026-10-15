# E9 - Farmer usability (Tamil)

Owner: SL, SS. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

>= 10 farmers in 2 villages. Tasks: find the pick list; play/read the Tamil alert; enter a trap count.
Then the 10-item System Usability Scale in Tamil (1 = strongly disagree ... 5 = strongly agree).
Success: mean SUS >= 68; >= 80 % task completion.

## Data in this folder

Use participant codes (P01...), never names or phone numbers. Tasks: 1 = completed without help, 0 = not.
Have the Tamil SUS translation checked by a native speaker before the test (U-13).

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E9` (or the notebook `E9.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
