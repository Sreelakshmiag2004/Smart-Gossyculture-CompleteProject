"""Farm → Device ownership and the single access rule used by all device data.

Access rule: a farmer may read a device only while it is ``active`` and attached to a farm they
own. Admins may read every registered device. Anything else is reported as "not found" so that
the existence of other farmers' devices is not revealed.

Registration lifecycle (no device certificates yet - U-7):
  admin registers  -> provisioned (one-time claim code, hash stored)
  farmer claims    -> active (attached to the farmer's farm)
  admin re-issues  -> provisioned again (detached; new code) - device transfer / lost label
  admin retires    -> decommissioned
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, select, update
from sqlalchemy.ext.asyncio import AsyncEngine

from gossy.api.errors import ApiError, not_found
from gossy.audit import audit
from gossy.auth.service import Principal
from gossy.contracts.topics import is_valid_device_id
from gossy.db.tables import device_status, devices, farms
from gossy.devices.schemas import Device, DeviceStatus, Farm
from gossy.security.otp import codes_match, hash_code, new_claim_code
from gossy.security.ratelimit import RateLimited, SlidingWindowLimiter


def _now() -> datetime:
    return datetime.now(UTC)


def _normalise_code(code: str) -> str:
    return code.replace(" ", "").replace("-", "").upper()


def _farm(row) -> Farm:
    return Farm(id=row.id, name=row.name, created_at=row.created_at)


_DEVICE_SELECT = select(
    devices.c.device_id, devices.c.display_name, devices.c.farm_id, devices.c.registration_state,
    devices.c.registered_at, devices.c.claimed_at,
    device_status.c.state, device_status.c.state_at, device_status.c.last_seen_at,
).select_from(devices.outerjoin(device_status, device_status.c.device_id == devices.c.device_id))


class DeviceService:
    def __init__(
        self, engine: AsyncEngine, claim_key: bytes, *, claim_code_ttl_s: int, claim_attempts_per_user: int = 10,
        telemetry_interval_s: int = 60, telemetry_stale_after_s: int = 180, clock: Callable[[], datetime] = _now,
    ):
        self._engine = engine
        self._key = claim_key
        self._ttl = timedelta(seconds=claim_code_ttl_s)
        self._telemetry_interval_s = telemetry_interval_s
        self._telemetry_stale_after_s = telemetry_stale_after_s
        self._clock = clock
        self.claim_limiter = SlidingWindowLimiter(claim_attempts_per_user, 600)

    def _device(self, row) -> Device:
        return Device(
            device_id=row.device_id, display_name=row.display_name, farm_id=row.farm_id,
            registration_state=row.registration_state, registered_at=row.registered_at, claimed_at=row.claimed_at,
            status=DeviceStatus(state=row.state, state_at=row.state_at, last_seen_at=row.last_seen_at),
            telemetry_interval_s=self._telemetry_interval_s, telemetry_stale_after_s=self._telemetry_stale_after_s,
        )

    # ------------------------------------------------------------------ access rule
    def _owned(self, principal: Principal):
        return and_(devices.c.registration_state == "active", farms.c.owner_user_id == principal.user_id)

    async def accessible_device_ids(self, principal: Principal) -> set[str]:
        async with self._engine.connect() as conn:
            if principal.is_admin:
                rows = await conn.execute(select(devices.c.device_id))
            else:
                rows = await conn.execute(select(devices.c.device_id).join(farms, farms.c.id == devices.c.farm_id).where(self._owned(principal)))
            return {r.device_id for r in rows}

    async def require_device(self, principal: Principal, device_id: str) -> None:
        if not await self._can_read(principal, device_id):
            raise not_found("Device")

    async def _can_read(self, principal: Principal, device_id: str) -> bool:
        query = select(devices.c.device_id).where(devices.c.device_id == device_id)
        if not principal.is_admin:
            query = query.join(farms, farms.c.id == devices.c.farm_id).where(self._owned(principal))
        async with self._engine.connect() as conn:
            return (await conn.execute(query)).first() is not None

    # ------------------------------------------------------------------ farms
    async def create_farm(self, principal: Principal, name: str) -> Farm:
        async with self._engine.begin() as conn:
            row = (await conn.execute(farms.insert().values(owner_user_id=principal.user_id, name=name, created_at=self._clock()).returning(farms))).one()
        await audit(self._engine, "farm.create", "success", actor=principal.user_id, target=str(row.id))
        return _farm(row)

    async def list_farms(self, principal: Principal) -> list[Farm]:
        async with self._engine.connect() as conn:
            rows = await conn.execute(select(farms).where(farms.c.owner_user_id == principal.user_id).order_by(farms.c.created_at))
            return [_farm(r) for r in rows]

    async def get_farm(self, principal: Principal, farm_id: uuid.UUID) -> Farm:
        async with self._engine.connect() as conn:
            row = (await conn.execute(select(farms).where(and_(farms.c.id == farm_id, farms.c.owner_user_id == principal.user_id)))).first()
        if row is None:
            raise not_found("Farm")
        return _farm(row)

    # ------------------------------------------------------------------ devices (farmer)
    async def list_devices(self, principal: Principal, farm_id: uuid.UUID | None = None) -> list[Device]:
        query = _DEVICE_SELECT.join(farms, farms.c.id == devices.c.farm_id).where(self._owned(principal))
        if farm_id is not None:
            query = query.where(devices.c.farm_id == farm_id)
        async with self._engine.connect() as conn:
            return [self._device(r) for r in await conn.execute(query.order_by(devices.c.device_id))]

    async def get_device(self, principal: Principal, device_id: str) -> Device:
        await self.require_device(principal, device_id)
        async with self._engine.connect() as conn:
            return self._device((await conn.execute(_DEVICE_SELECT.where(devices.c.device_id == device_id))).one())

    async def claim(self, principal: Principal, device_id: str, code: str, farm_id: uuid.UUID, client_ip: str | None) -> Device:
        try:
            self.claim_limiter.hit(f"user:{principal.user_id}")
        except RateLimited as exc:
            raise ApiError(429, "rate_limited", "Too many claim attempts. Try again later.", headers={"Retry-After": str(exc.retry_after_s)}) from None
        await self.get_farm(principal, farm_id)  # 404 if not the caller's farm
        now = self._clock()
        async with self._engine.begin() as conn:
            row = (await conn.execute(select(devices).where(devices.c.device_id == device_id).with_for_update())).first()
            ok = (
                row is not None
                and row.registration_state == "provisioned"
                and row.claim_code_hash is not None
                and row.claim_code_expires_at is not None
                and row.claim_code_expires_at > now
                and codes_match(row.claim_code_hash, self._key, f"claim:{device_id}", _normalise_code(code))
            )
            if ok:
                await conn.execute(
                    update(devices).where(devices.c.device_id == device_id).values(
                        registration_state="active", farm_id=farm_id, claimed_at=now, claimed_by=principal.user_id,
                        claim_code_hash=None, claim_code_expires_at=None,
                    )
                )
        if not ok:
            await audit(self._engine, "device.claim", "failure", actor=principal.user_id, target=device_id, client_ip=client_ip)
            raise ApiError(404, "claim_failed", "Device not found, not claimable, or the claim code is invalid or expired.")
        await audit(self._engine, "device.claim", "success", actor=principal.user_id, target=device_id, client_ip=client_ip, details={"farm_id": str(farm_id)})
        return await self.get_device(principal, device_id)

    # ------------------------------------------------------------------ devices (admin)
    def _issue_code(self, device_id: str, now: datetime) -> tuple[str, str, datetime]:
        code = new_claim_code()
        return code, hash_code(self._key, f"claim:{device_id}", _normalise_code(code)), now + self._ttl

    async def register(self, admin: Principal, device_id: str, display_name: str | None) -> tuple[Device, str, datetime]:
        if not is_valid_device_id(device_id):
            raise ApiError(422, "invalid_device_id", "The device id is not valid.")
        now = self._clock()
        code, code_hash, expires = self._issue_code(device_id, now)
        async with self._engine.begin() as conn:
            exists = (await conn.execute(select(devices.c.device_id).where(devices.c.device_id == device_id))).first()
            if exists is None:
                await conn.execute(
                    devices.insert().values(
                        device_id=device_id, display_name=display_name, registration_state="provisioned",
                        claim_code_hash=code_hash, claim_code_expires_at=expires, registered_at=now, registered_by=admin.user_id,
                    )
                )
        if exists is not None:
            raise ApiError(409, "device_exists", "A device with this id is already registered.")
        await audit(self._engine, "device.register", "success", actor=admin.user_id, target=device_id)
        return await self.get_device(admin, device_id), code, expires

    async def reissue_claim_code(self, admin: Principal, device_id: str) -> tuple[Device, str, datetime]:
        now = self._clock()
        code, code_hash, expires = self._issue_code(device_id, now)
        async with self._engine.begin() as conn:
            result = await conn.execute(
                update(devices).where(devices.c.device_id == device_id).values(
                    registration_state="provisioned", farm_id=None, claimed_at=None, claimed_by=None,
                    claim_code_hash=code_hash, claim_code_expires_at=expires, decommissioned_at=None,
                )
            )
        if result.rowcount == 0:
            raise not_found("Device")
        await audit(self._engine, "device.reissue_claim_code", "success", actor=admin.user_id, target=device_id)
        return await self.get_device(admin, device_id), code, expires

    async def decommission(self, admin: Principal, device_id: str) -> Device:
        async with self._engine.begin() as conn:
            result = await conn.execute(
                update(devices).where(devices.c.device_id == device_id).values(
                    registration_state="decommissioned", decommissioned_at=self._clock(), claim_code_hash=None, claim_code_expires_at=None,
                )
            )
        if result.rowcount == 0:
            raise not_found("Device")
        await audit(self._engine, "device.decommission", "success", actor=admin.user_id, target=device_id)
        return await self.get_device(admin, device_id)

    async def admin_list(self, state: str | None) -> list[Device]:
        query = _DEVICE_SELECT
        if state:
            query = query.where(devices.c.registration_state == state)
        async with self._engine.connect() as conn:
            return [self._device(r) for r in await conn.execute(query.order_by(devices.c.device_id))]
