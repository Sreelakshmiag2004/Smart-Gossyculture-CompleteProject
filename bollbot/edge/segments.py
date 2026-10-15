"""Know which row segment the cart is in, from row-marker sightings.

A tag must be seen in `confirm_frames` consecutive frames before the cart
switches segment, so a single false ArUco detection cannot split a segment.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional

from .markers import MarkerMap, SegmentRef


@dataclass
class ClosedSegment:
    ref: SegmentRef
    started: datetime
    ended: datetime
    frames: int


class SegmentTracker:
    def __init__(self, markers: MarkerMap, farm: str, confirm_frames: int = 2):
        if confirm_frames < 1:
            raise ValueError("confirm_frames must be >= 1")
        self.markers = markers
        self.farm = farm
        self.confirm_frames = confirm_frames
        self.current: Optional[SegmentRef] = None
        self._started: Optional[datetime] = None
        self._frames = 0
        self._candidate: Optional[SegmentRef] = None
        self._candidate_hits = 0
        self.ignored_tags: dict[int, str] = {}      # tag -> reason (diagnostics)

    def observe(self, tag_ids: list[int], ts: datetime) -> Optional[ClosedSegment]:
        """Feed the tags seen in one frame. Returns the segment that closed, if any."""
        if self.current is not None:
            self._frames += 1
        refs = []
        for tag in tag_ids:
            ref = self.markers.get(tag)
            if ref is None:
                self.ignored_tags[tag] = "not in markers.csv"
            elif ref.farm != self.farm:
                self.ignored_tags[tag] = f"belongs to farm {ref.farm}"
            else:
                refs.append(ref)
        # If several tags are visible, prefer one that is not the current segment.
        new = next((r for r in refs if r != self.current), None)
        if new is None:
            self._candidate, self._candidate_hits = None, 0
            return None
        if new == self._candidate:
            self._candidate_hits += 1
        else:
            self._candidate, self._candidate_hits = new, 1
        if self._candidate_hits < self.confirm_frames:
            return None
        closed = self._close(ts)
        self.current, self._started, self._frames = new, ts, 0
        self._candidate, self._candidate_hits = None, 0
        return closed

    def end(self, ts: datetime) -> Optional[ClosedSegment]:
        """Close the open segment at the end of a session."""
        closed = self._close(ts)
        self.current, self._started, self._frames = None, None, 0
        return closed

    def _close(self, ts: datetime) -> Optional[ClosedSegment]:
        if self.current is None:
            return None
        return ClosedSegment(self.current, self._started, ts, self._frames)
