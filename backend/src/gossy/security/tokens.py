"""Token strategy.

* Access token: JWT (HS256), short-lived (default 15 min). Claims: sub (user id), sid (session
  id), role, iss, aud, iat, exp, jti. Every request also checks that the session is not revoked,
  so logout and refresh-token reuse take effect immediately.
* Refresh token: 256-bit opaque random value. Only its SHA-256 hash is stored. Single use:
  each refresh rotates it; presenting a used token revokes the whole session (reuse detection).
"""

from __future__ import annotations

import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt

ALGORITHM = "HS256"
REFRESH_TOKEN_BYTES = 32


class InvalidToken(Exception):
    """Raised for any unusable access token. The reason is for logs only, never for clients."""


@dataclass(frozen=True)
class AccessClaims:
    user_id: uuid.UUID
    session_id: uuid.UUID
    role: str
    expires_at: datetime


class AccessTokenService:
    def __init__(self, key: bytes, *, issuer: str, audience: str, ttl_s: int):
        if len(key) < 32:
            raise ValueError("signing key must be at least 32 bytes")
        self._key = key
        self._issuer = issuer
        self._audience = audience
        self.ttl = timedelta(seconds=ttl_s)

    def issue(self, *, user_id: uuid.UUID, session_id: uuid.UUID, role: str, now: datetime | None = None) -> tuple[str, datetime]:
        now = now or datetime.now(UTC)
        expires = now + self.ttl
        claims = {
            "sub": str(user_id),
            "sid": str(session_id),
            "role": role,
            "iss": self._issuer,
            "aud": self._audience,
            "iat": int(now.timestamp()),
            "exp": int(expires.timestamp()),
            "jti": secrets.token_hex(8),
        }
        return jwt.encode(claims, self._key, algorithm=ALGORITHM), expires

    def verify(self, token: str) -> AccessClaims:
        try:
            claims = jwt.decode(
                token,
                self._key,
                algorithms=[ALGORITHM],  # never trust the token's own alg header
                audience=self._audience,
                issuer=self._issuer,
                options={"require": ["sub", "sid", "role", "exp", "iat", "iss", "aud"]},
            )
            return AccessClaims(
                user_id=uuid.UUID(claims["sub"]),
                session_id=uuid.UUID(claims["sid"]),
                role=str(claims["role"]),
                expires_at=datetime.fromtimestamp(claims["exp"], UTC),
            )
        except (jwt.PyJWTError, ValueError, KeyError) as exc:
            raise InvalidToken(type(exc).__name__) from None


def new_refresh_token() -> str:
    return secrets.token_urlsafe(REFRESH_TOKEN_BYTES)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
