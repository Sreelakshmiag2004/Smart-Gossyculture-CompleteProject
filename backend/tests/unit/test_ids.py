import pytest

from gossy.ids import is_ulid, new_ulid, ulid_timestamp_ms


def test_ulid_format_and_uniqueness():
    ids = {new_ulid() for _ in range(1000)}
    assert len(ids) == 1000
    assert all(is_ulid(i) and len(i) == 26 for i in ids)


def test_ulid_encodes_timestamp_and_sorts_by_time():
    early = new_ulid(timestamp_ms=1_700_000_000_000)
    late = new_ulid(timestamp_ms=1_700_000_000_001)
    assert ulid_timestamp_ms(early) == 1_700_000_000_000
    assert early < late


def test_ulid_deterministic_with_fixed_inputs():
    assert new_ulid(0, bytes(10)) == "0" * 26
    assert new_ulid((1 << 48) - 1, b"\xff" * 10) == "7" + "Z" * 25


@pytest.mark.parametrize("bad", ["", "0" * 25, "8" + "0" * 25, "0" * 25 + "U", "0" * 25 + "i"])
def test_is_ulid_rejects_invalid(bad):
    assert not is_ulid(bad)


def test_ulid_rejects_bad_inputs():
    with pytest.raises(ValueError):
        new_ulid(timestamp_ms=-1)
    with pytest.raises(ValueError):
        new_ulid(randomness=b"short")
