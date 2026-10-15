"""Build the train/val/test dataset by FARM (never by image).

Splitting by farm is what makes the test score honest: the model is tested
on a farm it has never seen (spec Section 6). Frames from one farm never
appear in two splits, and identical images across splits are refused.

Run:
  python -m bollbot.ml.split raw/ dataset/ --train F01 F02 --val F03 --test F04 \
      [--pretrain public/]   # public data: train split only, never val/test
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from collections import Counter
from pathlib import Path

import yaml

from bollbot.core.models import CLASSES
from .dataset import IMAGE_EXTS, file_hash, validate

SPLITS = ("train", "val", "test")


class SplitError(ValueError):
    pass


def check_assignment(farms_available: set[str], assignment: dict[str, list[str]]) -> list[str]:
    """Validate a split assignment; return warnings, raise SplitError on errors."""
    for s in SPLITS:
        if not assignment.get(s):
            raise SplitError(f"split '{s}' has no farms")
    seen: dict[str, str] = {}
    for s in SPLITS:
        for farm in assignment[s]:
            if farm not in farms_available:
                raise SplitError(f"farm '{farm}' not found in raw data")
            if farm in seen:
                raise SplitError(f"farm '{farm}' is in both '{seen[farm]}' and '{s}'")
            seen[farm] = s
    unused = sorted(farms_available - set(seen))
    return [f"farm '{f}' is not in any split" for f in unused]


def _place(src: Path, dst: Path, link: bool) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    if link:
        dst.symlink_to(src.resolve())
    else:
        shutil.copy2(src, dst)


def _prepare_out(out: Path, overwrite: bool) -> None:
    """Refuse to write into an existing split unless told to replace it.

    Re-running into the same folder used to leave files from the previous
    split behind, so a farm could end up in both train and test (QA bug 1).
    """
    existing = [out / n for n in ("images", "labels", "data.yaml", "manifest.json")
                if (out / n).exists()]
    if not existing:
        return
    if not overwrite:
        raise SplitError(f"{out} already contains a split; use a new out_dir "
                         f"or pass --overwrite to replace it")
    for p in existing:
        if p.is_dir() and not p.is_symlink():
            shutil.rmtree(p)
        else:
            p.unlink()


def build(raw_dir: str | Path, out_dir: str | Path, assignment: dict[str, list[str]],
          pretrain_dir: str | Path | None = None, link: bool = False,
          overwrite: bool = False) -> dict:
    """Create out_dir/{images,labels}/{train,val,test}, data.yaml and manifest.json."""
    raw, out = Path(raw_dir), Path(out_dir)
    _prepare_out(out, overwrite)
    rep = validate(raw)
    if not rep.ok:
        raise SplitError(f"raw dataset has {len(rep.errors)} errors; run "
                         f"'python -m bollbot.ml.dataset {raw}' and fix them first")
    warnings = check_assignment({f.farm for f in rep.farms}, assignment)

    sources: list[tuple[str, str, Path]] = []   # (split, farm, farm_dir)
    for s in SPLITS:
        for farm in assignment[s]:
            sources.append((s, farm, raw / farm))
    if pretrain_dir:
        pre = validate(pretrain_dir)
        if not pre.ok:
            raise SplitError("pretrain dataset has errors")
        for f in pre.farms:
            sources.append(("train", f"PUB-{f.farm}", Path(pretrain_dir) / f.farm))

    manifest = {"assignment": assignment, "pretrain": str(pretrain_dir) if pretrain_dir else None,
                "splits": {s: {"images": 0, "instances": dict.fromkeys(CLASSES, 0)} for s in SPLITS},
                "files": []}
    hash_split: dict[str, str] = {}
    for split, farm, farm_dir in sources:
        for img in sorted((farm_dir / "images").iterdir()):
            if img.suffix.lower() not in IMAGE_EXTS:
                continue
            digest = file_hash(img)
            if digest in hash_split and hash_split[digest] != split:
                raise SplitError(f"{farm}/{img.name} also appears in split "
                                 f"'{hash_split[digest]}' (leakage)")
            hash_split[digest] = split
            name = f"{farm}__{img.name}"            # farm prefix avoids name clashes
            _place(img, out / "images" / split / name, link)
            lbl = farm_dir / "labels" / f"{img.stem}.txt"
            dst_lbl = out / "labels" / split / f"{farm}__{img.stem}.txt"
            if lbl.exists():
                _place(lbl, dst_lbl, link)
                counts = Counter(int(ln.split()[0]) for ln in
                                 lbl.read_text(encoding="utf-8").splitlines() if ln.strip())
            else:
                dst_lbl.parent.mkdir(parents=True, exist_ok=True)
                dst_lbl.write_text("", encoding="utf-8")               # explicit background image
                counts = Counter()
            sp = manifest["splits"][split]
            sp["images"] += 1
            for cid, n in counts.items():
                sp["instances"][CLASSES[cid]] += n
            manifest["files"].append({"split": split, "farm": farm, "file": name, "md5": digest})

    data_yaml = {"path": str(out.resolve()), "train": "images/train", "val": "images/val",
                 "test": "images/test", "names": dict(enumerate(CLASSES))}
    (out / "data.yaml").write_text(yaml.safe_dump(data_yaml, sort_keys=False), encoding="utf-8")
    manifest["warnings"] = warnings
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Farm-wise train/val/test split")
    ap.add_argument("raw_dir")
    ap.add_argument("out_dir")
    for s in SPLITS:
        ap.add_argument(f"--{s}", nargs="+", required=True, metavar="FARM")
    ap.add_argument("--pretrain", help="public dataset in the same layout (train only)")
    ap.add_argument("--link", action="store_true", help="symlink instead of copying")
    ap.add_argument("--overwrite", action="store_true",
                    help="delete an existing split in out_dir first")
    a = ap.parse_args(argv)
    try:
        m = build(a.raw_dir, a.out_dir, {s: getattr(a, s) for s in SPLITS},
                  a.pretrain, a.link, a.overwrite)
    except SplitError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    for s in SPLITS:
        sp = m["splits"][s]
        print(f"{s:5s}: {sp['images']:5d} images  " +
              "  ".join(f"{k}={v}" for k, v in sp["instances"].items() if v))
    for w in m["warnings"]:
        print("WARN:", w)
    print(f"wrote {Path(a.out_dir) / 'data.yaml'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
