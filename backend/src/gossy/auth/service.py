"""Authentication service: OTP challenges, sessions, token issuing/rotation, principal lookup."""

from __future__ import annotations

import logging
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import and_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from gossy.audit import audit
from gossy.auth.schemas import TokenPair, UserProfile
from gossy.config import AuthSettings
from gossy.db.tables import auth_sessions, otp_challenges, refresh_tokens, users
from gossy.security.otp import OtpIssuer, codes_match, hash_code
from gossy.security.ratelimit import SlidingWindowLimiter
from gossy.security.tokens import AccessTokenService, InvalidToken, hash_token, new_refresh_token

log = logging.getLogger("gossy.auth")


class AuthFailed(Exception):
    """Generic authentication failure. The public message never says which check failed."""


@dataclass(frozen=True)
class Principal:
    user_id: uuid.UUID
    session_id: uuid.UUID
    role: str
    token_expires_at: datetime

    @property
    def is_admin(self) -> bool:
        return self.role == "admin"


def _now() -> datetime:
    return datetime.now(UTC)


def profile(row) -> UserProfile:
    return UserProfile(
        id=row.id, phone=row.phone_e164, display_name=row.display_name, role=row.role,
        created_at=row.created_at, last_login_at=row.last_login_at,
    )


class AuthService:
    def __init__(self, engine: AsyncEngine, settings: AuthSettings, tokens: AccessTokenService, issuer: OtpIssuer, *, clock: Callable[[], datetime] = _now):
        self._engine = engine
        self._settings = settings
        self._tokens = tokens
        self._issuer = issuer
        self._otp_key = settings.otp_hmac_key()
        self._clock = clock
        window = settings.rate_window_s
        self.phone_limiter = SlidingWindowLimiter(settings.otp_requests_per_phone, window)
        self.ip_limiter = SlidingWindowLimiter(settings.otp_requests_per_ip, window)
        self.verify_ip_limiter = SlidingWindowLimiter(settings.otp_verifications_per_ip, window)

    @property
    def otp_mode(self) -> str:
        return self._issuer.mode

    # ------------------------------------------------------------------ OTP
    async def request_otp(self, phone: str, client_ip: str | None) -> None:
        self.ip_limiter.hit(f"ip:{client_ip}")
        self.phone_limiter.hit(f"phone:{phone}")
        code = self._issuer.issue(phone)  # may raise OtpDeliveryUnavailable
        if code is None:
            await audit(self._engine, "auth.otp_request", "denied", target=_mask(phone), client_ip=client_ip, details={"reason": "not_eligible", "mode": self.otp_mode})
            return
        now = self._clock()
        async with self._engine.begin() as conn:
            # Only the newest challenge is ever valid: a new request supersedes older ones.
            await conn.execute(_consume_outstanding(phone, now))
            await conn.execute(
                otp_challenges.insert().values(
                    phone_e164=phone, code_hash=hash_code(self._otp_key, phone, code),
                    created_at=now, expires_at=now + timedelta(seconds=self._settings.otp_ttl_s), attempts=0,
                )
            )
        await audit(self._engine, "auth.otp_request", "success", target=_mask(phone), client_ip=client_ip, details={"mode": self.otp_mode})

    async def verify_otp(self, phone: str, code: str, client_ip: str | None) -> TokenPair:
        self.verify_ip_limiter.hit(f"ip:{client_ip}")
        now = self._clock()
        async with self._engine.begin() as conn:
            challenge = (
                await conn.execute(
                    select(otp_challenges)
                    .where(and_(otp_challenges.c.phone_e164 == phone, otp_challenges.c.consumed_at.is_(None), otp_challenges.c.expires_at > now))
                    .order_by(otp_challenges.c.created_at.desc())
                    .limit(1)
                    .with_for_update()
                )
            ).first()
            reason = None
            if challenge is None:
                reason = "no_active_challenge"
            elif challenge.attempts >= self._settings.otp_max_attempts:
                reason = "too_many_attempts"
            else:
                await conn.execute(update(otp_challenges).where(otp_challenges.c.id == challenge.id).values(attempts=challenge.attempts + 1))
                if not codes_match(challenge.code_hash, self._otp_key, phone, code):
                    reason = "wrong_code"
            if reason is None:
                # Consume every outstanding challenge for this phone, so no code can be used twice.
                await conn.execute(_consume_outstanding(phone, now))
                user = await self._get_or_create_user(conn, phone, now)
                if user.status != "active":
                    reason = "user_disabled"
                else:
                    pair = await self._start_session(conn, user, now)
        # Outside the transaction: failed attempts are committed before we answer.
        if reason is not None:
            await audit(self._engine, "auth.login", "failure", target=_mask(phone), client_ip=client_ip, details={"reason": reason})
            raise AuthFailed(reason)
        await audit(self._engine, "auth.login", "success", actor=pair.user.id, client_ip=client_ip)
        return pair

    async def _get_or_create_user(self, conn: AsyncConnection, phone: str, now: datetime):
        # New numbers become farmers. Admins are only created by the operator CLI (gossy.manage).
        await conn.execute(
            pg_insert(users).values(phone_e164=phone, role="farmer", status="active", created_at=now).on_conflict_do_nothing(index_elements=["phone_e164"])
        )
        await conn.execute(update(users).where(users.c.phone_e164 == phone).values(last_login_at=now))
        return (await conn.execute(select(users).where(users.c.phone_e164 == phone))).one()

    async def _start_session(self, conn: AsyncConnection, user, now: datetime) -> TokenPair:
        refresh_expires = now + timedelta(seconds=self._settings.refresh_token_ttl_s)
        session_id = (
            await conn.execute(auth_sessions.insert().values(user_id=user.id, created_at=now, expires_at=refresh_expires).returning(auth_sessions.c.id))
        ).scalar_one()
        return await self._issue_pair(conn, user, session_id, now, refresh_expires)

    async def _issue_pair(self, conn: AsyncConnection, user, session_id: uuid.UUID, now: datetime, refresh_expires: datetime) -> TokenPair:
        refresh = new_refresh_token()
        await conn.execute(refresh_tokens.insert().values(token_hash=hash_token(refresh), session_id=session_id, issued_at=now, expires_at=refresh_expires))
        access, access_expires = self._tokens.issue(user_id=user.id, session_id=session_id, role=user.role, now=now)
        return TokenPair(
            access_token=access, access_token_expires_at=access_expires,
            refresh_token=refresh, refresh_token_expires_at=refresh_expires, user=profile(user),
        )

    # ------------------------------------------------------------------ refresh / logout
    async def refresh(self, token: str, client_ip: str | None) -> TokenPair:
        now = self._clock()
        reuse_session: uuid.UUID | None = None
        reason = None
        async with self._engine.begin() as conn:
            row = (
                await conn.execute(
                    select(refresh_tokens, auth_sessions.c.user_id, auth_sessions.c.revoked_at, auth_sessions.c.expires_at.label("session_expires_at"))
                    .join(auth_sessions, auth_sessions.c.id == refresh_tokens.c.session_id)
                    .where(refresh_tokens.c.token_hash == hash_token(token))
                    .with_for_update()
                )
            ).first()
            if row is None:
                reason = "unknown_token"
            elif row.used_at is not None:
                # Reuse of a rotated token: assume theft and revoke the whole session.
                reason = "refresh_token_reuse"
                reuse_session = row.session_id
                await conn.execute(
                    update(auth_sessions).where(and_(auth_sessions.c.id == row.session_id, auth_sessions.c.revoked_at.is_(None))).values(revoked_at=now, revoke_reason="refresh_reuse")
                )
            elif row.revoked_at is not None or row.expires_at <= now or row.session_expires_at <= now:
                reason = "session_inactive"
            else:
                user = (await conn.execute(select(users).where(users.c.id == row.user_id))).one()
                if user.status != "active":
                    reason = "user_disabled"
                else:
                    await conn.execute(update(refresh_tokens).where(refresh_tokens.c.token_hash == row.token_hash).values(used_at=now))
                    pair = await self._issue_pair(conn, user, row.session_id, now, row.session_expires_at)
        if reason is not None:
            await audit(self._engine, "auth.refresh", "failure", client_ip=client_ip, target=str(reuse_session) if reuse_session else None, details={"reason": reason})
            raise AuthFailed(reason)
        await audit(self._engine, "auth.refresh", "success", actor=pair.user.id, client_ip=client_ip)
        return pair

    async def logout(self, principal: Principal, client_ip: str | None) -> None:
        async with self._engine.begin() as conn:
            await conn.execute(
                update(auth_sessions).where(and_(auth_sessions.c.id == principal.session_id, auth_sessions.c.revoked_at.is_(None))).values(revoked_at=self._clock(), revoke_reason="logout")
            )
        await audit(self._engine, "auth.logout", "success", actor=principal.user_id, client_ip=client_ip)

    # ------------------------------------------------------------------ principals
    async def authenticate(self, token: str) -> Principal:
        """Validate an access token AND that its session/user are still active."""
        try:
            claims = self._tokens.verify(token)
        except InvalidToken as exc:
            log.info("access_token_rejected", extra={"reason": str(exc)})
            raise AuthFailed("invalid_token") from None
        now = self._clock()
        async with self._engine.connect() as conn:
            row = (
                await conn.execute(
                    select(users.c.role, users.c.status, auth_sessions.c.revoked_at, auth_sessions.c.expires_at)
                    .join(auth_sessions, auth_sessions.c.user_id == users.c.id)
                    .where(and_(auth_sessions.c.id == claims.session_id, users.c.id == claims.user_id))
                )
            ).first()
        if row is None or row.revoked_at is not None or row.expires_at <= now or row.status != "active":
            raise AuthFailed("session_inactive")
        # The database role is authoritative (a demoted admin loses rights immediately).
        return Principal(user_id=claims.user_id, session_id=claims.session_id, role=row.role, token_expires_at=claims.expires_at)

    async def get_profile(self, user_id: uuid.UUID) -> UserProfile:
        async with self._engine.connect() as conn:
            return profile((await conn.execute(select(users).where(users.c.id == user_id))).one())

    async def update_profile(self, user_id: uuid.UUID, display_name: str) -> UserProfile:
        async with self._engine.begin() as conn:
            await conn.execute(update(users).where(users.c.id == user_id).values(display_name=display_name))
            return profile((await conn.execute(select(users).where(users.c.id == user_id))).one())


def _consume_outstanding(phone: str, now: datetime):
    return update(otp_challenges).where(and_(otp_challenges.c.phone_e164 == phone, otp_challenges.c.consumed_at.is_(None))).values(consumed_at=now)


def _mask(phone: str) -> str:
    """Audit/log form of a phone number: keep country prefix and last 2 digits."""
    return phone[:3] + "*" * max(0, len(phone) - 5) + phone[-2:]
