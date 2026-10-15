"""In-process sliding-window rate limiter.

Scope: one API process. With several API replicas each keeps its own counters, so the effective
limit multiplies by the replica count; a shared store (e.g. Redis) is needed before scaling out.
"""

from __future__ import annotations

import time
from collections import defaultdict, deque
from collections.abc import Callable


class RateLimited(Exception):
    def __init__(self, retry_after_s: int):
        super().__init__("rate limited")
        self.retry_after_s = retry_after_s


class SlidingWindowLimiter:
    def __init__(self, limit: int, window_s: float, *, clock: Callable[[], float] = time.monotonic, max_keys: int = 100_000):
        self._limit = limit
        self._window = window_s
        self._clock = clock
        self._max_keys = max_keys
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def hit(self, key: str) -> None:
        """Record an attempt for ``key`` or raise RateLimited if the window is full."""
        now = self._clock()
        bucket = self._hits[key]
        while bucket and now - bucket[0] >= self._window:
            bucket.popleft()
        if len(bucket) >= self._limit:
            raise RateLimited(max(1, int(self._window - (now - bucket[0])) + 1))
        bucket.append(now)
        if len(self._hits) > self._max_keys:
            self._evict(now)

    def _evict(self, now: float) -> None:
        for key in [k for k, b in self._hits.items() if not b or now - b[-1] >= self._window]:
            del self._hits[key]
