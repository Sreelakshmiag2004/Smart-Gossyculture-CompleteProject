"""Tests for the ML pipeline parts that do not need Ultralytics (Module 2)."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import yaml
from PIL import Image

from bollbot.core.config import load_ml
from bollbot.core.models import CLASSES
from bollbot.ml.dataset import parse_label_line, validate
from bollbot.ml.evaluate import extract_metrics
from bollbot.ml.metrics import (check_targets, counting_errors, normalise_rows,
                                rare_classes, speed_from_latencies, top_confusions)
from bollbot.ml.split import SplitError, build, check_assignment

TARGETS = load_ml()["targets"]


def make_image(path: Path, seed: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (32, 32), (seed % 256, (seed * 7) % 256, (seed * 13) % 256)).save(path)


def make_farm(root: Path, farm: str, n: int, seed0: int, labels: dict[int, str] | None = None):
    """n images; labels[i] = label text for image i (default: one open boll)."""
    for i in range(n):
        make_image(root / farm / "images" / f"{farm}_{i:03d}.jpg", seed0 + i)
        txt = (labels or {}).get(i, "2 0.5 0.5 0.2 0.2\n")
        if txt is not None:
            lbl = root / farm / "labels" / f"{farm}_{i:03d}.txt"
            lbl.parent.mkdir(parents=True, exist_ok=True)
            lbl.write_text(txt)


class LabelParseTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(parse_label_line("7 0.5 0.5 0.1 0.2"), (7, 0.5, 0.5, 0.1, 0.2))

    def test_invalid(self):
        for bad, msg in [("8 0.5 0.5 0.1 0.1", "outside"), ("x 0.5 0.5 0.1 0.1", "integer"),
                         ("1 0.5 0.5 0.1", "5 values"), ("1 1.2 0.5 0.1 0.1", "centre"),
                         ("1 0.5 0.5 0 0.1", "size"), ("1 0.95 0.5 0.2 0.1", "outside the image")]:
            with self.assertRaisesRegex(ValueError, msg):
                parse_label_line(bad)


class ValidateTests(unittest.TestCase):
    def test_counts_and_issues(self):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d)
            make_farm(raw, "F01", 3, 0, {1: "0 0.5 0.5 0.2 0.2\n5 0.3 0.3 0.1 0.1\n", 2: None})
            (raw / "F01" / "labels" / "orphan.txt").write_text("2 0.5 0.5 0.1 0.1\n")
            make_farm(raw, "F02", 2, 50, {0: "9 0.5 0.5 0.1 0.1\n"})
            rep = validate(raw)
            f1 = rep.farms[0]
            self.assertEqual(f1.images, 3)
            self.assertEqual(f1.background_images, 1)
            self.assertEqual(f1.instances["boll_open"], 1)
            self.assertEqual(f1.instances["rosette_flower"], 1)
            msgs = [i.message for i in rep.errors]
            self.assertTrue(any("no matching image" in m for m in msgs))
            self.assertTrue(any("class id 9" in m for m in msgs))
            self.assertFalse(rep.ok)

    def test_cross_farm_duplicate_is_error(self):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d)
            make_farm(raw, "F01", 2, 0)
            make_farm(raw, "F02", 2, 1)       # F02_000 identical to F01_001
            rep = validate(raw)
            self.assertTrue(any("cross-farm duplicate" in i.message for i in rep.errors))


class SplitTests(unittest.TestCase):
    def test_assignment_rules(self):
        farms = {"F01", "F02", "F03", "F04"}
        with self.assertRaisesRegex(SplitError, "both"):
            check_assignment(farms, {"train": ["F01"], "val": ["F01"], "test": ["F02"]})
        with self.assertRaisesRegex(SplitError, "no farms"):
            check_assignment(farms, {"train": ["F01"], "val": [], "test": ["F02"]})
        with self.assertRaisesRegex(SplitError, "not found"):
            check_assignment(farms, {"train": ["F09"], "val": ["F02"], "test": ["F03"]})
        warn = check_assignment(farms, {"train": ["F01"], "val": ["F02"], "test": ["F03"]})
        self.assertEqual(warn, ["farm 'F04' is not in any split"])

    def test_build(self):
        with tempfile.TemporaryDirectory() as d:
            raw, out, pub = Path(d) / "raw", Path(d) / "ds", Path(d) / "pub"
            make_farm(raw, "F01", 3, 0)
            make_farm(raw, "F02", 2, 100, {1: None})        # one background image
            make_farm(raw, "F03", 2, 200)
            make_farm(pub, "roboflow", 2, 300)
            m = build(raw, out, {"train": ["F01"], "val": ["F02"], "test": ["F03"]}, pretrain_dir=pub)
            self.assertEqual(m["splits"]["train"]["images"], 5)         # 3 own + 2 public
            self.assertEqual(m["splits"]["val"]["images"], 2)
            self.assertEqual(m["splits"]["test"]["instances"]["boll_open"], 2)
            data = yaml.safe_load((out / "data.yaml").read_text())
            self.assertEqual(data["names"][2], "boll_open")
            self.assertEqual(len(data["names"]), len(CLASSES))
            self.assertTrue((out / "images" / "test" / "F03__F03_000.jpg").exists())
            bg = out / "labels" / "val" / "F02__F02_001.txt"
            self.assertEqual(bg.read_text(), "")                        # explicit background
            self.assertFalse(any(f["split"] != "train" and f["farm"].startswith("PUB")
                                 for f in m["files"]))

    def test_build_refuses_dirty_raw(self):
        with tempfile.TemporaryDirectory() as d:
            raw = Path(d) / "raw"
            make_farm(raw, "F01", 1, 0, {0: "8 0.5 0.5 0.2 0.2\n"})
            make_farm(raw, "F02", 1, 10)
            make_farm(raw, "F03", 1, 20)
            with self.assertRaisesRegex(SplitError, "errors"):
                build(raw, Path(d) / "ds", {"train": ["F01"], "val": ["F02"], "test": ["F03"]})


class MetricTests(unittest.TestCase):
    def test_targets(self):
        res = check_targets({"map50": 0.83, "per_class": {"boll_open": {"recall": 0.80}},
                             "fps": 4.2}, TARGETS)
        by = {r.kpi: r.met for r in res}
        self.assertTrue(by["mAP@50 (test farm)"])
        self.assertFalse(by["boll_open recall"])
        self.assertTrue(by["FPS on edge"])
        self.assertIsNone(by["counting MAPE %"])        # not measured yet

    def test_rare_classes(self):
        inst = dict.fromkeys(CLASSES, 500)
        inst.update(rosette_flower=40, mealybug_colony=99)
        self.assertEqual(rare_classes(inst, 100), ["rosette_flower", "mealybug_colony"])

    def test_confusions(self):
        m = [[8, 2, 0], [1, 9, 0], [0, 0, 0]]
        self.assertEqual(normalise_rows(m)[0], [0.8, 0.2, 0.0])
        self.assertEqual(normalise_rows(m)[2], [0.0, 0.0, 0.0])
        top = top_confusions(m, ["closed", "open", "bg"])
        self.assertEqual(top[0], ("closed", "open", 0.2))

    def test_counting(self):
        rows = [{"segment": "S1", "cls": "boll_open", "true": 20, "pred": 18},
                {"segment": "S2", "cls": "boll_open", "true": 10, "pred": 12},
                {"segment": "S3", "cls": "boll_open", "true": 0, "pred": 1}]
        r = counting_errors(rows)[0]
        self.assertEqual(r.mae, round(5 / 3, 3))
        self.assertEqual(r.mape, 15.0)          # (10% + 20%) / 2; S3 excluded (true = 0)
        self.assertEqual(r.bias_pct, round((31 - 30) / 30 * 100, 2))

    def test_speed(self):
        lat = [1.0] * 5 + [0.25] * 20               # 5 warm-up frames dropped
        s = speed_from_latencies(lat)
        self.assertEqual(s.frames, 20)
        self.assertEqual(s.fps, 4.0)
        self.assertEqual(s.latency_p50_ms, 250.0)


class ExtractTests(unittest.TestCase):
    def test_confusion_is_transposed_to_true_rows(self):
        names = ["a", "b"]
        # Ultralytics layout: matrix[pred][true]; 3x3 with background last.
        # 5 true 'a' predicted as 'b'; 7 true 'b' correct.
        matrix = [[3, 0, 0], [5, 7, 0], [0, 0, 0]]
        fake = SimpleNamespace(
            ap_class_index=[0, 1],
            box=SimpleNamespace(p=[0.9, 0.6], r=[0.4, 1.0], ap50=[0.5, 0.9], ap=[0.3, 0.6],
                                map50=0.7, map=0.45, mp=0.75, mr=0.7),
            confusion_matrix=SimpleNamespace(matrix=matrix))
        out = extract_metrics(fake, names)
        self.assertEqual(out["confusion"]["counts_true_rows"][0], [3.0, 5.0, 0.0])
        self.assertEqual(out["top_confusions"][0], {"true": "a", "pred": "b", "share": 0.625})
        self.assertEqual(out["per_class"]["b"]["recall"], 1.0)
        json.dumps(out)                                  # serialisable


if __name__ == "__main__":
    unittest.main()
