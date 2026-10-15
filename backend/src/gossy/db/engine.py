from __future__ import annotations

from sqlalchemy import URL
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from gossy.config import DatabaseSettings


def database_url(settings: DatabaseSettings) -> URL:
    """Same URL for async (app) and sync (Alembic) use: psycopg 3 supports both."""
    return URL.create(
        "postgresql+psycopg",
        username=settings.user,
        password=settings.password_value(),
        host=settings.host,
        port=settings.port,
        database=settings.name,
    )


def create_engine(settings: DatabaseSettings) -> AsyncEngine:
    return create_async_engine(
        database_url(settings),
        pool_size=settings.pool_size,
        pool_pre_ping=True,
        connect_args={"connect_timeout": settings.connect_timeout_s, "application_name": "gossy"},
    )
