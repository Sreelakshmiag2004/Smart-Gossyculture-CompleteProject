# E5 - Depth and localisation

Owner: DK. Protocol and success criterion: spec Section 13 (targets frozen in `bollbot/config/experiments.yaml`).

## Protocol

20 white balls on a pegboard at known 3D positions, 0.4-0.8 m from the camera: stereo estimate vs truth.
Arm touch test (`python -m bollbot.edge.arm.harvest goto ...`): miss distance with a ruler.
Segment IDs: 10 rows, logged segment vs the marker actually passed.
Success: mean camera error <= 2 cm; arm within 3 cm on >= 80 % of points; 100 % correct segment IDs.

## Data in this folder

Coordinates in the CAMERA frame, metres (x right, y down, z forward). `arm_miss_cm` may be empty.

Copy a `*_template` file, remove `_template` from its name, and fill it. Lines starting with `#` are ignored.

## Analysis

`python -m bollbot.analysis.report --only E5` (or the notebook `E5.ipynb`). A missed target is reported as
missed, with its value and reason: never drop it, never change the target afterwards.
