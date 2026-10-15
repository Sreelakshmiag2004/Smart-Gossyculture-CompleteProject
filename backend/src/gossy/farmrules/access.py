"""Who may do what on a farm.

| Caller            | Read status/advice/data | Enter data | Location, members |
|-------------------|-------------------------|------------|-------------------|
| owner             | yes                     | yes        | yes               |
| operator (member) | yes                     | yes        | no (403)          |
| admin             | yes                     | no (403)   | no (403)          |
| anyone else       | 404 (existence not revealed)                      |

Operators get no access to the farm's devices (telemetry, claim): that stays with the owner.
"""

from __future__ import annotations

import uuid
from typing import Literal

from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.api.errors import forbidden, not_found
from gossy.auth.service import Principal
from gossy.db.tables import farm_members, farms

FarmRole = Literal["owner", "operator", "admin"]


async def farm_role(engine: AsyncEngine, principal: Principal, farm_id: uuid.UUID) -> FarmRole:
    async with engine.connect() as conn:
        owner = (await conn.execute(select(farms.c.owner_user_id).where(farms.c.id == farm_id))).scalar_one_or_none()
        if owner is None:
            raise not_found("Farm")
        if owner == principal.user_id:
            return "owner"
        member = (await conn.execute(select(farm_members.c.role).where(and_(
            farm_members.c.farm_id == farm_id, farm_members.c.user_id == principal.user_id, farm_members.c.removed_at.is_(None),
        )))).scalar_one_or_none()
    if member == "operator":
        return "operator"
    if principal.is_admin:
        return "admin"
    raise not_found("Farm")


async def require_reader(engine: AsyncEngine, principal: Principal, farm_id: uuid.UUID) -> FarmRole:
    return await farm_role(engine, principal, farm_id)


async def require_writer(engine: AsyncEngine, principal: Principal, farm_id: uuid.UUID) -> FarmRole:
    role = await farm_role(engine, principal, farm_id)
    if role not in ("owner", "operator"):
        raise forbidden("Only the farm's owner or an operator can enter data.")
    return role


async def require_owner(engine: AsyncEngine, principal: Principal, farm_id: uuid.UUID) -> None:
    if await farm_role(engine, principal, farm_id) != "owner":
        raise forbidden("Only the farm's owner can do this.")
