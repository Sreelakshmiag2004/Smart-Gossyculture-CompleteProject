"""Validate a raw YOLO dataset organised by farm, and report class statistics.

Expected raw layout (one folder per farm, folder name = farm ID):

    raw/
      F01/
        images/  F01_S1_R012_0001.jpg ...
        labels/  F01_S1_R012_0001.txt ...   (YOLO: class cx cy w h, normalised)
      F02/ ...

An image with no label file is treated as background (no objects), which
YOLO allows, but it is reported so the team can check it was intended.

Run:  python -m bollbot.ml.dataset raw/  [--check-images] [--json report.json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

from bollbot.core.models import CLASSES

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".bmp"}
TINY_BOX_AREA = 1e-4      # < 0.01% of the image: likely a mis-click
EDGE_TOL = 1e-3           # tolerance for boxes touching the border


@dataclass
class Issue:
    severity: str          # ERROR | WARN
    farm: str
    file: str
    message: str


@dataclass
class FarmStats:
    farm: str
    images: int = 0
    background_images: int = 0
    instances: dict[str, int] = field(default_factory=lambda: {c: 0 for c in CLASSES})


@dataclass
class DatasetReport:
    farms: list[FarmStats]
    issues: list[Issue]

    @property
    def errors(self) -> list[Issue]:
        return [i for i in self.issues if i.severity == "ERROR"]

    @property
    def ok(self) -> bool:
        return not self.errors

    def totals(self) -> dict[str, int]:
        t: Counter = Counter()
        for f in self.farms:
            t.update(f.instances)
        return {c: t.get(c, 0) for c in CLASSES}

    def to_dict(self) -> dict:
        return {"ok": self.ok, "totals": self.totals(),
                "farms": [asdict(f) for f in self.farms],
                "issues": [asdict(i) for i in self.issues]}


def parse_label_line(line: str) -> tuple[int, float, float, float, float]:
    """Parse one YOLO label line; raise ValueError with a clear message."""
    parts = line.split()
    if len(parts) != 5:
        raise ValueError(f"expected 5 values, got {len(parts)}")
    try:
        cls = int(parts[0])
    except ValueError:
        raise ValueError(f"class id '{parts[0]}' is not an integer") from None
    if not 0 <= cls < len(CLASSES):
        raise ValueError(f"class id {cls} outside 0..{len(CLASSES) - 1}")
    cx, cy, w, h = (float(p) for p in parts[1:])
    if not (0 <= cx <= 1 and 0 <= cy <= 1):
        raise ValueError(f"centre ({cx}, {cy}) not in [0, 1]")
    if not (0 < w <= 1 and 0 < h <= 1):
        raise ValueError(f"size ({w}, {h}) not in (0, 1]")
    if (cx - w / 2 < -EDGE_TOL or cx + w / 2 > 1 + EDGE_TOL or
            cy - h / 2 < -EDGE_TOL or cy + h / 2 > 1 + EDGE_TOL):
        raise ValueError("box extends outside the image")
    return cls, cx, cy, w, h


def file_hash(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _check_image(path: Path) -> str | None:
    try:
        from PIL import Image
        with Image.open(path) as im:
            im.verify()
        return None
    except Exception as e:  # noqa: BLE001 - any decode failure is reportable
        return f"unreadable image: {e}"


def validate(raw_dir: str | Path, check_images: bool = False) -> DatasetReport:
    raw = Path(raw_dir)
    if not raw.is_dir():
        raise FileNotFoundError(raw)
    farms, issues = [], []
    seen_hash: dict[str, tuple[str, str]] = {}

    # Hidden folders (.ipynb_checkpoints, .git, ...) are not farms (QA bug 9).
    for farm_dir in sorted(p for p in raw.iterdir() if p.is_dir() and not p.name.startswith(".")):
        farm = farm_dir.name
        st = FarmStats(farm)
        img_dir, lbl_dir = farm_dir / "images", farm_dir / "labels"
        if not img_dir.is_dir():
            issues.append(Issue("ERROR", farm, str(farm_dir), "missing images/ folder"))
            farms.append(st)
            continue
        image_files = [p for p in img_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS]
        # Two images with one stem (x.jpg + x.png) would share one label file (QA bug 8).
        for stem, n in sorted(Counter(p.stem for p in image_files).items()):
            if n > 1:
                issues.append(Issue("ERROR", farm, stem,
                                    f"{n} images share this name; they would share one label file"))
        images = {p.stem: p for p in image_files}
        labels = {p.stem: p for p in lbl_dir.glob("*.txt")} if lbl_dir.is_dir() else {}

        for stem in sorted(set(labels) - set(images)):
            issues.append(Issue("ERROR", farm, labels[stem].name, "label has no matching image"))

        for stem, img in sorted(images.items()):
            st.images += 1
            digest = file_hash(img)
            if digest in seen_hash:
                other_farm, other = seen_hash[digest]
                sev = "ERROR" if other_farm != farm else "WARN"
                issues.append(Issue(sev, farm, img.name,
                                    f"identical to {other_farm}/{other}"
                                    + (" (cross-farm duplicate: leaks into test)" if sev == "ERROR" else "")))
            else:
                seen_hash[digest] = (farm, img.name)
            if check_images and (err := _check_image(img)):
                issues.append(Issue("ERROR", farm, img.name, err))

            lbl = labels.get(stem)
            if lbl is None:
                st.background_images += 1
                issues.append(Issue("WARN", farm, img.name, "no label file (treated as background)"))
                continue
            lines = [ln.strip() for ln in lbl.read_text(encoding="utf-8").splitlines() if ln.strip()]
            if not lines:
                st.background_images += 1
            seen_lines = set()
            for n, line in enumerate(lines, 1):
                try:
                    cls, _, _, w, h = parse_label_line(line)
                except ValueError as e:
                    issues.append(Issue("ERROR", farm, f"{lbl.name}:{n}", str(e)))
                    continue
                if line in seen_lines:
                    issues.append(Issue("WARN", farm, f"{lbl.name}:{n}", "duplicate box"))
                seen_lines.add(line)
                if w * h < TINY_BOX_AREA:
                    issues.append(Issue("WARN", farm, f"{lbl.name}:{n}", "very small box"))
                st.instances[CLASSES[cls]] += 1
        farms.append(st)
    if not farms:
        issues.append(Issue("ERROR", "-", str(raw), "no farm folders found"))
    return DatasetReport(farms, issues)


def format_report(rep: DatasetReport, max_issues: int = 30) -> str:
    lines = [f"{'class':18s}" + "".join(f"{f.farm:>8s}" for f in rep.farms) + f"{'TOTAL':>8s}"]
    tot = rep.totals()
    for c in CLASSES:
        lines.append(f"{c:18s}" + "".join(f"{f.instances[c]:8d}" for f in rep.farms) + f"{tot[c]:8d}")
    lines.append(f"{'images':18s}" + "".join(f"{f.images:8d}" for f in rep.farms)
                 + f"{sum(f.images for f in rep.farms):8d}")
    errs = len(rep.errors)
    lines.append(f"\n{errs} errors, {len(rep.issues) - errs} warnings")
    for i in rep.issues[:max_issues]:
        lines.append(f"  [{i.severity}] {i.farm}/{i.file}: {i.message}")
    if len(rep.issues) > max_issues:
        lines.append(f"  ... {len(rep.issues) - max_issues} more (use --json)")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("raw_dir")
    ap.add_argument("--check-images", action="store_true", help="decode every image (slower)")
    ap.add_argument("--json", help="write the full report to this JSON file")
    a = ap.parse_args(argv)
    rep = validate(a.raw_dir, a.check_images)
    print(format_report(rep))
    if a.json:
        Path(a.json).write_text(json.dumps(rep.to_dict(), indent=2))
    return 0 if rep.ok else 1


if __name__ == "__main__":
    sys.exit(main())
