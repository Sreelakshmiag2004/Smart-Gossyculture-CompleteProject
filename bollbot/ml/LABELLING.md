# Labelling guide – BollBot detector

Use Label Studio or Roboflow (free tier). Export in **YOLO format**, then arrange files as `raw/<FARM>/images` and `raw/<FARM>/labels`. Class IDs must match this table exactly; it is the order in `core/models.py`.

| ID | Class | Label when… | Do NOT label when… |
|---|---|---|---|
| 0 | boll_closed | Green / green-brown capsule, no lint visible | Square (bud with bracts only): leave as background |
| 1 | boll_cracking | Sutures split, lint visible but not fluffed out | Lint fully out of the locules → class 2 |
| 2 | boll_open | Lint fluffed out of most locules, pickable | Lint grey/stained or hard-locked → class 3 |
| 3 | boll_defective | Rotten, stained, hard-locked or insect-damaged open boll | Healthy open boll partly hidden by a leaf |
| 4 | flower | Open cream/pink flower | Rosette flower → class 5 |
| 5 | rosette_flower | Petals webbed shut (pink bollworm sign) | Normal flower closing in the evening |
| 6 | boll_bored | Closed boll with an entry/exit hole or frass | Bird peck on an open boll |
| 7 | mealybug_colony | White waxy cluster on stem, petiole or boll | Lint fragments stuck on leaves |

## Rules

1. Draw tight boxes around the **visible** part only.
2. Label an object only if **30% or more** of it is visible.
3. Label every instance in the image. A missed boll teaches the model that bolls are background.
4. When unsure between two classes, add the image to `doubtful.txt` and decide as a team. Do not guess.
5. Name images `<FARM>_<SESSION>_<ROW>_<NNNN>.jpg`, e.g. `F01_S2_R012_0043.jpg`.
6. **Double-label 10% of images.** Two people label the same images independently. Report the agreement as the share of boxes matched at IoU ≥ 0.5, with the same class.

## Before every training run

```bash
python -m bollbot.ml.dataset raw/          # must say 0 errors
```
