from datetime import UTC, datetime, timedelta

import pytest

from gossy.api.errors import ApiError
from gossy.api.pagination import check_time_range, decode_cursor, encode_cursor

T = datetime(2026, 9, 29, 12, 0, tzinfo=UTC)


def test_cursor_roundtrip_is_opaque():
    cursor = encode_cursor(T, "01K6CQ4W0D8V9J4Q9W2Y1S7ZPX")
    assert "2026" not in cursor and "=" not in cursor
    assert decode_cursor(cursor) == (T, "01K6CQ4W0D8V9J4Q9W2Y1S7ZPX")


@pytest.mark.parametrize(
    "bad",
    [
        "",
        "!!!",
        "bm90LWpzb24",  # base64 of "not-json"
        "WyIyMDI2LTA5LTI5VDEyOjAwOjAwIiwgImEiXQ",  # ["2026-09-29T12:00:00", "a"]: naive timestamp
    ],
)
def test_invalid_cursor_is_a_422(bad):
    with pytest.raises(ApiError) as exc:
        decode_cursor(bad)
    assert (exc.value.status, exc.value.code) == (422, "invalid_cursor")


def test_time_range_must_be_increasing():
    check_time_range(T, T + timedelta(seconds=1))
    check_time_range(None, T)
    with pytest.raises(ApiError) as exc:
        check_time_range(T, T)
    assert exc.value.code == "invalid_time_range"
