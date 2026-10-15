"""Turn per-frame tracked detections into per-segment counts (spec Sections 6, 13 E3).

The tracker (ByteTrack on the Pi, or the OAK-D's ObjectTracker) gives each
boll a track ID that persists across frames. A boll is counted ONCE, when
its segment closes, if it was seen in at least `min_hits` frames. Its class
is the confidence-weighted majority over all frames, so a boll that flickers
between 'cracking' and 'open' is counted once, in its dominant class.
"""
from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Iterable, Optional

from bollbot.core.models import CLASSES


@dataclass
class Detection:
    cls_id: int
    conf: float
    xyxy: tuple[float, float, float, float]       # pixels
    track_id: Optional[int] = None
    xyz_m: Optional[tuple[float, float, float]] = None   # camera frame, metres (stereo)

    @property
    def cls(self) -> str:
        return CLASSES[self.cls_id]


@dataclass
class _Track:
    hits: int = 0
    votes: dict[int, float] = field(default_factory=lambda: defaultdict(float))


class TrackCounter:
    def __init__(self, min_hits: int = 3, min_conf: float = 0.0, memory: int = 10000):
        if min_hits < 1:
            raise ValueError("min_hits must be >= 1")
        self.min_hits = min_hits
        self.min_conf = min_conf
        self._tracks: dict[int, _Track] = {}
        self._counted: dict[int, None] = {}   # insertion-ordered set of counted IDs
        self._memory = memory
        self.untracked = 0                    # detections without a track ID (diagnostic)

    def update(self, detections: Iterable[Detection]) -> None:
        for d in detections:
            if d.conf < self.min_conf:
                continue
            if d.track_id is None:
                self.untracked += 1
                continue
            if d.track_id in self._counted:
                continue          # already counted in an earlier segment
            t = self._tracks.setdefault(d.track_id, _Track())
            t.hits += 1
            t.votes[d.cls_id] += d.conf

    def finalize(self) -> dict[str, int]:
        """Counts for the segment that just closed; resets for the next one.

        Tracks still visible are counted now and remembered, so a boll that
        straddles two segments is counted once, in the first one.
        """
        counts = dict.fromkeys(CLASSES, 0)
        for tid, t in self._tracks.items():
            if t.hits < self.min_hits:
                continue
            cls_id = max(t.votes.items(), key=lambda kv: (kv[1], -kv[0]))[0]
            counts[CLASSES[cls_id]] += 1
            self._counted[tid] = None
        self._tracks.clear()
        while len(self._counted) > self._memory:          # bounded memory on long runs
            self._counted.pop(next(iter(self._counted)))
        return counts

    def discard(self) -> None:
        """Drop tracks seen outside any segment (before the first marker)."""
        self._tracks.clear()
