"""Farm rules API: farm status and advice, operator membership, and data entry (trap counts,
scouting counts, detection confirmations). Entering data re-runs the farm's rules at once, so the
next status read reflects it. Nothing here reaches a device."""

from __future__ import annotations

import uuid
from datetime import UTC, date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request, Response
from sqlalchemy import String, and_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert

from gossy.api.deps import CurrentPrincipal, service
from gossy.api.errors import ApiError, not_found, responses
from gossy.api.pagination import DEFAULT_LIMIT, MAX_LIMIT, Page
from gossy.audit import audit
from gossy.db.tables import detection_confirmations, farm_advisories, farm_members, farm_status, scouting_observations, trap_counts, users
from gossy.farmrules import access, logic
from gossy.farmrules.schemas import (
    Advisory, Confirmation, ConfirmationIn, FarmMember, FarmStatus, MemberAdd, Observation, ObservationIn, PestRule, TrapCount, TrapCountIn,
)
from gossy.farmrules.store import FarmRulesStore
from gossy.telemetry.queries import all_of, keyset_page

router = APIRouter(prefix="/api/v1")
Store = Annotated[FarmRulesStore, Depends(service("farmrules"))]
MAX_PAST_DAYS = 60  # data entry for older days would not change any rule (history window: 14 days)
Days = Annotated[int, Query(ge=1, le=MAX_PAST_DAYS, description="How many days back, counted from today (Indian date)")]
DATA = ["farm-rules"]


def _now() -> datetime:
    return datetime.now(UTC)


def _check_day(day: date, now: datetime) -> None:
    today = logic.ist_today(now)
    if day > today:
        raise ApiError(422, "invalid_date", "The date is in the future (Indian date).")
    if day < today - timedelta(days=MAX_PAST_DAYS):
        raise ApiError(422, "invalid_date", f"The date is more than {MAX_PAST_DAYS} days ago.")


def _since(days: int, now: datetime) -> date:
    return logic.ist_today(now) - timedelta(days=days - 1)


# ----------------------------------------------------------------------------- catalog
@router.get("/farm-rules/catalog", response_model=list[PestRule], responses=responses(401), tags=DATA, summary="Pest threshold rules (ETLs) with their scouting keys")
async def catalog(principal: CurrentPrincipal) -> list[PestRule]:
    return [PestRule.model_validate(r) for r in logic.catalog()]


# ----------------------------------------------------------------------------- status and advice
@router.get("/farms/{farm_id}/status", response_model=FarmStatus, responses=responses(401, 404, 422), tags=DATA, summary="Segment readiness, picking window, weather and pest thresholds for a farm")
async def get_status(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> FarmStatus:
    await access.require_reader(store.engine, principal, farm_id)
    async with store.engine.connect() as conn:
        row = (await conn.execute(select(farm_status.c.doc).where(farm_status.c.farm_id == farm_id))).first()
    if row is None:
        return FarmStatus(farm_id=farm_id, computed_at=None)
    return FarmStatus.model_validate({**row.doc, "farm_id": farm_id})


@router.post("/farms/{farm_id}/status/recompute", response_model=FarmStatus, responses=responses(401, 403, 404, 422), tags=DATA, summary="Re-run the farm's rules now (uses the cached forecast)")
async def recompute_status(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> FarmStatus:
    await access.require_reader(store.engine, principal, farm_id)
    doc = await store.recompute(farm_id)
    return FarmStatus.model_validate({**doc, "farm_id": farm_id})


def _advisory(r) -> Advisory:
    return Advisory(
        id=r.id, type=r.type, pest=r.pest, segments=list(r.segments or []), reason=r.reason, text_en=r.text_en, text_ta=r.text_ta,
        active=r.active, created_at=r.created_at, updated_at=r.updated_at, resolved_at=r.resolved_at,
    )


@router.get("/farms/{farm_id}/advisories", response_model=Page[Advisory], responses=responses(401, 404, 422), tags=DATA, summary="Advice for a farm, newest first")
async def list_advisories(
    farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store,
    active: Annotated[bool | None, Query(description="true: current advice only; false: resolved only")] = None,
    limit: Annotated[int, Query(ge=1, le=MAX_LIMIT)] = DEFAULT_LIMIT,
    cursor: Annotated[str | None, Query(max_length=512)] = None,
) -> Page[Advisory]:
    await access.require_reader(store.engine, principal, farm_id)
    clauses = [farm_advisories.c.farm_id == farm_id]
    if active is not None:
        clauses.append(farm_advisories.c.active.is_(active))
    items, nxt = await keyset_page(
        store.engine, select(farm_advisories).where(all_of(clauses)),
        time_col=farm_advisories.c.created_at, key_col=farm_advisories.c.id.cast(String), cursor=cursor, limit=limit,
        to_item=_advisory, key_of=lambda r: (r.created_at, str(r.id)),
    )
    return Page[Advisory](items=items, nextCursor=nxt)


# ----------------------------------------------------------------------------- members (operators)
def _member(r) -> FarmMember:
    return FarmMember(user_id=r.user_id, phone=r.phone_e164, display_name=r.display_name, role=r.role, added_at=r.added_at)


_MEMBER_SELECT = select(farm_members.c.user_id, farm_members.c.role, farm_members.c.added_at, users.c.phone_e164, users.c.display_name).join(
    users, users.c.id == farm_members.c.user_id
)


@router.get("/farms/{farm_id}/members", response_model=list[FarmMember], responses=responses(401, 403, 404, 422), tags=["farms"], summary="Operators of a farm (owner only)")
async def list_members(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> list[FarmMember]:
    await access.require_owner(store.engine, principal, farm_id)
    async with store.engine.connect() as conn:
        rows = await conn.execute(_MEMBER_SELECT.where(and_(farm_members.c.farm_id == farm_id, farm_members.c.removed_at.is_(None))).order_by(farm_members.c.added_at))
        return [_member(r) for r in rows]


@router.post("/farms/{farm_id}/members", status_code=201, response_model=FarmMember, responses=responses(401, 403, 404, 422), tags=["farms"], summary="Add an operator by phone number (owner only)")
async def add_member(farm_id: uuid.UUID, body: MemberAdd, principal: CurrentPrincipal, store: Store) -> FarmMember:
    await access.require_owner(store.engine, principal, farm_id)
    now = _now()
    async with store.engine.begin() as conn:
        # The operator signs in later with this number; the account is created now if needed.
        await conn.execute(pg_insert(users).values(phone_e164=body.phone, role="farmer", status="active", created_at=now).on_conflict_do_nothing(index_elements=["phone_e164"]))
        user_id = (await conn.execute(select(users.c.id).where(users.c.phone_e164 == body.phone))).scalar_one()
        if user_id == principal.user_id:
            raise ApiError(422, "owner_is_not_operator", "The farm's owner already has full access.")
        await conn.execute(
            pg_insert(farm_members).values(farm_id=farm_id, user_id=user_id, role="operator", added_at=now, added_by=principal.user_id)
            .on_conflict_do_update(index_elements=["farm_id", "user_id"], set_={"role": "operator", "added_at": now, "added_by": principal.user_id, "removed_at": None})
        )
        row = (await conn.execute(_MEMBER_SELECT.where(and_(farm_members.c.farm_id == farm_id, farm_members.c.user_id == user_id)))).one()
    await audit(store.engine, "farm.member_add", "success", actor=principal.user_id, target=str(farm_id), details={"user_id": str(user_id)})
    return _member(row)


@router.delete("/farms/{farm_id}/members/{user_id}", status_code=204, response_class=Response, responses=responses(401, 403, 404, 422), tags=["farms"], summary="Remove an operator (owner only)")
async def remove_member(farm_id: uuid.UUID, user_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> Response:
    await access.require_owner(store.engine, principal, farm_id)
    async with store.engine.begin() as conn:
        result = await conn.execute(
            update(farm_members).where(and_(farm_members.c.farm_id == farm_id, farm_members.c.user_id == user_id, farm_members.c.removed_at.is_(None))).values(removed_at=_now())
        )
    if result.rowcount == 0:
        raise not_found("Member")
    await audit(store.engine, "farm.member_remove", "success", actor=principal.user_id, target=str(farm_id), details={"user_id": str(user_id)})
    return Response(status_code=204)


# ----------------------------------------------------------------------------- trap counts
def _trap(r) -> TrapCount:
    return TrapCount(id=r.id, trap=r.trap, night=r.night, moths=r.moths, recorded_at=r.recorded_at, recorded_by=r.recorded_by)


@router.post("/farms/{farm_id}/traps", status_code=201, response_model=TrapCount, responses=responses(401, 403, 404, 422), tags=DATA, summary="Record a pheromone-trap count (replaces the same trap's count for that night)")
async def add_trap_count(farm_id: uuid.UUID, body: TrapCountIn, principal: CurrentPrincipal, store: Store) -> TrapCount:
    await access.require_writer(store.engine, principal, farm_id)
    now = _now()
    _check_day(body.night, now)
    trap = body.trap.upper()
    if trap.split("-")[0] not in logic.trap_prefixes():
        raise ApiError(422, "unknown_trap_type", f"Unknown trap type. Known prefixes: {', '.join(sorted(logic.trap_prefixes()))}.")
    live = and_(trap_counts.c.farm_id == farm_id, trap_counts.c.trap == trap, trap_counts.c.night == body.night, trap_counts.c.deleted_at.is_(None))
    async with store.engine.begin() as conn:
        await conn.execute(update(trap_counts).where(live).values(deleted_at=now))  # a correction replaces the earlier count
        row = (await conn.execute(trap_counts.insert().values(
            farm_id=farm_id, trap=trap, night=body.night, moths=body.moths, recorded_by=principal.user_id, recorded_at=now,
        ).returning(trap_counts))).one()
    await store.recompute(farm_id)
    return _trap(row)


@router.get("/farms/{farm_id}/traps", response_model=list[TrapCount], responses=responses(401, 404, 422), tags=DATA, summary="Trap counts, newest night first")
async def list_trap_counts(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store, days: Days = 30) -> list[TrapCount]:
    await access.require_reader(store.engine, principal, farm_id)
    async with store.engine.connect() as conn:
        rows = await conn.execute(select(trap_counts).where(and_(
            trap_counts.c.farm_id == farm_id, trap_counts.c.deleted_at.is_(None), trap_counts.c.night >= _since(days, _now()),
        )).order_by(trap_counts.c.night.desc(), trap_counts.c.trap))
        return [_trap(r) for r in rows]


async def _soft_delete(store: FarmRulesStore, table, farm_id: uuid.UUID, record_id: uuid.UUID, what: str) -> Response:
    async with store.engine.begin() as conn:
        result = await conn.execute(
            update(table).where(and_(table.c.id == record_id, table.c.farm_id == farm_id, table.c.deleted_at.is_(None))).values(deleted_at=_now())
        )
    if result.rowcount == 0:
        raise not_found(what)
    await store.recompute(farm_id)
    return Response(status_code=204)


@router.delete("/farms/{farm_id}/traps/{record_id}", status_code=204, response_class=Response, responses=responses(401, 403, 404, 422), tags=DATA, summary="Remove a trap count entered by mistake")
async def delete_trap_count(farm_id: uuid.UUID, record_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> Response:
    await access.require_writer(store.engine, principal, farm_id)
    return await _soft_delete(store, trap_counts, farm_id, record_id, "Trap count")


# ----------------------------------------------------------------------------- scouting observations
def _observation(r, rules: dict) -> Observation:
    return Observation(
        id=r.id, observed_on=r.observed_on, observation=r.observation, pest=rules.get(r.observation, {}).get("pest", r.observation),
        count=r.count, units=r.units, row=r.row_no, segment=r.segment_no, recorded_at=r.recorded_at, recorded_by=r.recorded_by,
    )


@router.post("/farms/{farm_id}/observations", status_code=201, response_model=Observation, responses=responses(401, 403, 404, 422), tags=DATA, summary="Record a scouting count (e.g. aphid-infested plants out of 20 examined)")
async def add_observation(farm_id: uuid.UUID, body: ObservationIn, principal: CurrentPrincipal, store: Store) -> Observation:
    await access.require_writer(store.engine, principal, farm_id)
    now = _now()
    _check_day(body.observed_on, now)
    rules = logic.observation_rules()
    rule = rules.get(body.observation)
    if rule is None:
        raise ApiError(422, "unknown_observation", f"Unknown observation. Known keys: {', '.join(sorted(rules))}.")
    if rule["type"] == "percent_units" and body.count > body.units:
        raise ApiError(422, "count_exceeds_units", "This observation counts plants, so the count cannot exceed the plants examined.")
    if (body.row is None) != (body.segment is None):
        raise ApiError(422, "invalid_location", "Send row and segment together, or neither.")
    async with store.engine.begin() as conn:
        row = (await conn.execute(scouting_observations.insert().values(
            farm_id=farm_id, observed_on=body.observed_on, observation=body.observation, count=body.count, units=body.units,
            row_no=body.row, segment_no=body.segment, recorded_by=principal.user_id, recorded_at=now,
        ).returning(scouting_observations))).one()
    await store.recompute(farm_id)
    return _observation(row, rules)


@router.get("/farms/{farm_id}/observations", response_model=list[Observation], responses=responses(401, 404, 422), tags=DATA, summary="Scouting counts, newest day first")
async def list_observations(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store, days: Days = 30) -> list[Observation]:
    await access.require_reader(store.engine, principal, farm_id)
    rules = logic.observation_rules()
    async with store.engine.connect() as conn:
        rows = await conn.execute(select(scouting_observations).where(and_(
            scouting_observations.c.farm_id == farm_id, scouting_observations.c.deleted_at.is_(None), scouting_observations.c.observed_on >= _since(days, _now()),
        )).order_by(scouting_observations.c.observed_on.desc(), scouting_observations.c.recorded_at.desc()))
        return [_observation(r, rules) for r in rows]


@router.delete("/farms/{farm_id}/observations/{record_id}", status_code=204, response_class=Response, responses=responses(401, 403, 404, 422), tags=DATA, summary="Remove a scouting count entered by mistake")
async def delete_observation(farm_id: uuid.UUID, record_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> Response:
    await access.require_writer(store.engine, principal, farm_id)
    return await _soft_delete(store, scouting_observations, farm_id, record_id, "Observation")


# ----------------------------------------------------------------------------- detection confirmations
def _confirmation(r) -> Confirmation:
    return Confirmation(
        id=r.id, observed_on=r.observed_on, row=r.row_no, segment=r.segment_no, class_name=r.class_name, verdict=r.verdict,
        source_msg_id=r.source_msg_id, recorded_at=r.recorded_at, recorded_by=r.recorded_by,
    )


@router.post("/farms/{farm_id}/confirmations", status_code=201, response_model=Confirmation, responses=responses(401, 403, 404, 422), tags=DATA, summary="Record that a camera detection was checked on the plant (confirmed or rejected)")
async def add_confirmation(farm_id: uuid.UUID, body: ConfirmationIn, principal: CurrentPrincipal, store: Store) -> Confirmation:
    await access.require_writer(store.engine, principal, farm_id)
    now = _now()
    _check_day(body.observed_on, now)
    async with store.engine.begin() as conn:
        row = (await conn.execute(detection_confirmations.insert().values(
            farm_id=farm_id, observed_on=body.observed_on, row_no=body.row, segment_no=body.segment, class_name=body.class_name,
            verdict=body.verdict, source_msg_id=body.source_msg_id, recorded_by=principal.user_id, recorded_at=now,
        ).returning(detection_confirmations))).one()
    await store.recompute(farm_id)
    return _confirmation(row)


@router.get("/farms/{farm_id}/confirmations", response_model=list[Confirmation], responses=responses(401, 404, 422), tags=DATA, summary="Checked detections, newest day first")
async def list_confirmations(farm_id: uuid.UUID, principal: CurrentPrincipal, store: Store, days: Days = 30) -> list[Confirmation]:
    await access.require_reader(store.engine, principal, farm_id)
    async with store.engine.connect() as conn:
        rows = await conn.execute(select(detection_confirmations).where(and_(
            detection_confirmations.c.farm_id == farm_id, detection_confirmations.c.deleted_at.is_(None), detection_confirmations.c.observed_on >= _since(days, _now()),
        )).order_by(detection_confirmations.c.observed_on.desc(), detection_confirmations.c.recorded_at.desc()))
        return [_confirmation(r) for r in rows]


@router.delete("/farms/{farm_id}/confirmations/{record_id}", status_code=204, response_class=Response, responses=responses(401, 403, 404, 422), tags=DATA, summary="Remove a confirmation entered by mistake")
async def delete_confirmation(farm_id: uuid.UUID, record_id: uuid.UUID, principal: CurrentPrincipal, store: Store) -> Response:
    await access.require_writer(store.engine, principal, farm_id)
    return await _soft_delete(store, detection_confirmations, farm_id, record_id, "Confirmation")
