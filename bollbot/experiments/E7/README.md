# E7 - Spot-spray targeting (water + dye only)

Owner: DK, SS. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

Plot of 100 tagged plants; 30 randomly marked 'infested' with a white sticker.
A dye card on each target plant and on its 2 neighbours. Run the cart; the sprayer fires on detected targets under interlock.
Hit = dye covers >= 10 % of the card. Weigh the tank before and after (water: 1 g = 1 ml).
Success: >= 90 % targets hit, <= 10 % non-target cards hit, volume <= 40 % of blanket (100 x 27 ml).

## Data in this folder

`card`: target or neighbour. Either type `deposit_pct`, or leave it empty and put the card photo (cropped to the
card) in this folder with its file name in `image`: the analysis measures the dyed area with OpenCV.
Measure the dye's hue once on a fully sprayed and a clean card before the experiment.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E7` (or the notebook `E7.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
