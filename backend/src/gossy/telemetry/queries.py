from __future__ import annotations

from collections.abc import Callable, Sequence
from datetime import datetime
from typing import TypeVar

from sqlalchemy import Select, and_, tuple_
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.api.pagination import decode_cursor, encode_cursor

T = TypeVar("T")


def time_window(column, start: datetime | None, end: datetime | None) -> list:
    clauses = []
    if start is not None:
        clauses.append(column >= start)
    if end is not None:
        clauses.append(column < end)
    return clauses


async def keyset_page(
    engine: AsyncEngine,
    query: Select,
    *,
    time_col,
    key_col,
    cursor: str | None,
    limit: int,
    to_item: Callable[[object], T],
    key_of: Callable[[object], tuple[datetime, str]],
) -> tuple[Sequence[T], str | None]:
    """Newest-first page of ``limit`` items plus the cursor for the next page."""
    if cursor:
        ts, key = decode_cursor(cursor)
        query = query.where(tuple_(time_col, key_col) < tuple_(ts, key))
    query = query.order_by(time_col.desc(), key_col.desc()).limit(limit + 1)
    async with engine.connect() as conn:
        rows = list(await conn.execute(query))
    more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = encode_cursor(*key_of(rows[-1])) if more and rows else None
    return [to_item(r) for r in rows], next_cursor


def all_of(clauses: list):
    return and_(*clauses) if clauses else and_(True)
