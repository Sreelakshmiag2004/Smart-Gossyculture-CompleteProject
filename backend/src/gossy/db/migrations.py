from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from alembic.config import Config
from alembic.script import ScriptDirectory

# src/gossy/db/migrations.py -> backend root
BACKEND_ROOT = Path(__file__).resolve().parents[3]


@lru_cache(maxsize=1)
def expected_head() -> str:
    """The migration revision this build of the code expects the database to be at."""
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_ROOT / "migrations"))
    heads = ScriptDirectory.from_config(config).get_heads()
    if len(heads) != 1:
        raise RuntimeError(f"expected exactly one migration head, found {heads}")
    return heads[0]
