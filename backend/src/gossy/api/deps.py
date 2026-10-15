"""FastAPI dependencies: services from app state, client IP, authenticated principal."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from gossy.api.errors import ApiError, forbidden, unauthenticated
from gossy.auth.service import AuthFailed, AuthService, Principal

bearer = HTTPBearer(
    auto_error=False,
    scheme_name="BearerAuth",
    description="Access token from `POST /api/v1/auth/otp/verify` or `/api/v1/auth/refresh` (JWT, 15 min).",
)


def service(name: str):
    def _get(request: Request):
        svc = getattr(request.app.state, name, None)
        if svc is None:
            raise ApiError(503, "service_unavailable", "The service is not available.")
        return svc

    return _get


def client_ip(request: Request) -> str | None:
    # Direct peer address. Behind a reverse proxy this must become the trusted forwarded address.
    return request.client.host if request.client else None


async def current_principal(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
    auth: Annotated[AuthService, Depends(service("auth"))],
) -> Principal:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise unauthenticated()
    try:
        return await auth.authenticate(credentials.credentials)
    except AuthFailed:
        raise unauthenticated("The access token is invalid or expired.") from None


async def admin_principal(principal: Annotated[Principal, Depends(current_principal)]) -> Principal:
    if not principal.is_admin:
        raise forbidden()
    return principal


CurrentPrincipal = Annotated[Principal, Depends(current_principal)]
AdminPrincipal = Annotated[Principal, Depends(admin_principal)]
ClientIp = Annotated[str | None, Depends(client_ip)]
