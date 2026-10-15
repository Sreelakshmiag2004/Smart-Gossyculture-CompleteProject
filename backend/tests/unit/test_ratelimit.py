import pytest

from gossy.security.ratelimit import RateLimited, SlidingWindowLimiter


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def test_limit_then_window_expiry():
    clock = Clock()
    lim = SlidingWindowLimiter(3, 60, clock=clock)
    for _ in range(3):
        lim.hit("phone:a")
    with pytest.raises(RateLimited) as exc:
        lim.hit("phone:a")
    assert 1 <= exc.value.retry_after_s <= 61
    lim.hit("phone:b")  # keys are independent
    clock.t += 60
    lim.hit("phone:a")  # window has slid


def test_rejected_attempts_do_not_extend_the_window():
    clock = Clock()
    lim = SlidingWindowLimiter(1, 10, clock=clock)
    lim.hit("k")
    for _ in range(5):
        clock.t += 1
        with pytest.raises(RateLimited):
            lim.hit("k")
    clock.t += 5
    lim.hit("k")


def test_idle_keys_are_evicted():
    clock = Clock()
    lim = SlidingWindowLimiter(1, 10, clock=clock, max_keys=5)
    for i in range(5):
        lim.hit(f"k{i}")
    clock.t += 11
    lim.hit("new")
    assert len(lim._hits) <= 2
