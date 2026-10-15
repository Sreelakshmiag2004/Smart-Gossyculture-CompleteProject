# Experiments E1–E11

Each folder holds one experiment's protocol (README.md), its data templates, its data and a
notebook. Targets are frozen in `bollbot/config/experiments.yaml` (spec Section 13).

| ID | What | Owner | Data file(s) | Success |
|---|---|---|---|---|
| E1 | Detector quality | DK | `eval_test.json`, `manifest.json` | mAP@50 ≥ 0.80, open-boll recall ≥ 0.85 |
| E2 | Edge speed | DK | `speed*.json` | ≥ 3 FPS at 416 px |
| E3 | Counting accuracy | DK, SS | `counts.csv`, `scan_times.csv` | cart MAPE ≤ 15 %; ≤ 60 min/acre |
| E4 | Picking-window rule | SS | `moisture.csv` | ≥ 85 % agreement on the test half |
| E5 | Depth & localisation | DK | `pegboard.csv`, `segments.csv` | mean ≤ 2 cm; arm ≤ 3 cm on 80 %; 100 % segment IDs |
| E6 | Pest signals + ETL logic | SS, DK | `rule_cases.yaml`, `pest_signals.csv` | rule cases 100 % pass; P/R reported |
| E7 | Spot-spray targeting | DK, SS | `cards.csv` (+ photos), `volume.csv` | ≥ 90 % hit, ≤ 10 % non-target, ≤ 40 % volume |
| E8 | IoT reliability | SL | `outbox.sqlite`, `backend_messages.csv`, `session.yaml` | 0 lost; median ≤ 10 s online |
| E9 | Farmer usability | SL, SS | `sus.csv` | SUS ≥ 68; ≥ 80 % tasks |
| E10 | Arm demonstrator | DK | `picks.csv` | ≥ 60 % success; trash ≤ 10 % |
| E11 | Power | SL | `power*.csv`, `session.yaml` | ≥ 4 h per charge |

Write the protocol before collecting data, and never change a target after seeing results. A
missed target is reported as missed, with the reason.

    python -m bollbot.analysis.report            # all experiments -> results.md + figures/
    python -m bollbot.analysis.report --only E4  # one experiment
