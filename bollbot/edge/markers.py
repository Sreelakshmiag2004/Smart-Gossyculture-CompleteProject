"""ArUco row markers (spec Section 7).

Each stake carries a printed ArUco tag. config/markers.csv maps the tag's
number to a farm, row and segment. ArUco IDs are small numbers (0-249 for
DICT_4X4_250), so the mapping lives in the CSV, not in the ID itself.

Print a sheet of tags (one PNG per tag, labelled with its segment):
  python -m bollbot.edge.markers sheet --csv bollbot/config/markers.csv --out markers/
"""
from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SegmentRef:
    farm: str
    row: int
    segment: int

    @property
    def key(self) -> str:
        return f"R{self.row:03d}-S{self.segment:02d}"


class MarkerMap:
    """tag_id -> SegmentRef, loaded from markers.csv and validated."""

    def __init__(self, mapping: dict[int, SegmentRef]):
        self._m = dict(mapping)

    @classmethod
    def load(cls, path: str | Path) -> "MarkerMap":
        mapping: dict[int, SegmentRef] = {}
        seen_refs: dict[SegmentRef, int] = {}
        with open(path, newline="", encoding="utf-8") as fh:
            reader = csv.DictReader(fh)
            need = {"tag_id", "farm", "row", "segment"}
            if not reader.fieldnames or not need <= set(reader.fieldnames):
                raise ValueError(f"{path}: columns must be {sorted(need)}")
            for n, r in enumerate(reader, start=2):
                try:
                    tag = int(r["tag_id"])
                    ref = SegmentRef(r["farm"].strip(), int(r["row"]), int(r["segment"]))
                except (TypeError, ValueError) as e:
                    raise ValueError(f"{path}:{n}: {e}") from None
                if tag in mapping:
                    raise ValueError(f"{path}:{n}: tag {tag} used twice")
                if ref in seen_refs:
                    raise ValueError(f"{path}:{n}: {ref.farm} {ref.key} already has tag {seen_refs[ref]}")
                if ref.row < 1 or ref.segment < 1 or not ref.farm:
                    raise ValueError(f"{path}:{n}: farm must be set; row and segment start at 1")
                mapping[tag] = ref
                seen_refs[ref] = tag
        return cls(mapping)

    def get(self, tag_id: int) -> SegmentRef | None:
        return self._m.get(tag_id)

    def tags(self) -> list[int]:
        return sorted(self._m)

    def __len__(self) -> int:
        return len(self._m)


class ArucoReader:
    """Find ArUco tag IDs in a BGR or grey frame (OpenCV >= 4.7 API)."""

    def __init__(self, dictionary: str = "DICT_4X4_250"):
        import cv2
        if not hasattr(cv2.aruco, dictionary):
            raise ValueError(f"unknown ArUco dictionary {dictionary}")
        self._cv2 = cv2
        d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, dictionary))
        self._det = cv2.aruco.ArucoDetector(d, cv2.aruco.DetectorParameters())

    def detect(self, frame) -> list[int]:
        cv2 = self._cv2
        grey = frame if frame.ndim == 2 else cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        _, ids, _ = self._det.detectMarkers(grey)
        return [] if ids is None else sorted(int(i) for i in ids.ravel())


def make_sheet(markers: MarkerMap, out_dir: str | Path, dictionary: str = "DICT_4X4_250",
               px: int = 600) -> list[Path]:
    """Write one printable PNG per tag: the tag with a white border and its label.
    Print at >= 10 cm wide, laminate, and mount facing the camera's side."""
    import cv2
    import numpy as np
    d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, dictionary))
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    paths = []
    for tag in markers.tags():
        ref = markers.get(tag)
        border = px // 6
        img = np.full((px + 2 * border + 90, px + 2 * border), 255, np.uint8)
        img[border:border + px, border:border + px] = cv2.aruco.generateImageMarker(d, tag, px)
        label = f"{ref.farm} {ref.key}  (tag {tag})"
        cv2.putText(img, label, (border, px + border + 60), cv2.FONT_HERSHEY_SIMPLEX,
                    1.4, 0, 3, cv2.LINE_AA)
        p = out / f"tag_{tag:03d}_{ref.farm}_{ref.key}.png"
        cv2.imwrite(str(p), img)
        paths.append(p)
    return paths


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Row-marker tools")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sheet", help="write printable tag images")
    s.add_argument("--csv", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--dictionary", default="DICT_4X4_250")
    a = ap.parse_args(argv)
    paths = make_sheet(MarkerMap.load(a.csv), a.out, a.dictionary)
    print(f"wrote {len(paths)} tag images to {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
