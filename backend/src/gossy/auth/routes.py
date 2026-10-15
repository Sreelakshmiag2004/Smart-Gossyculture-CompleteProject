from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Response

from gossy.api.deps import ClientIp, CurrentPrincipal, service
from gossy.api.errors import ApiError, responses
from gossy.auth.schemas import OtpRequest, OtpRequestAccepted, OtpVerify, RefreshRequest, TokenPair, UpdateProfile, UserProfile
from gossy.auth.service import AuthFailed, AuthService
from gossy.security.otp import OtpDeliveryUnavailable
from gossy.security.ratelimit import RateLimited

router = APIRouter(prefix="/api/v1", tags=["auth"])
Auth = Annotated[AuthService, Depends(service("auth"))]


def _invalid() -> ApiError:
    return ApiError(401, "invalid_credentials", "The phone number or code is invalid, expired or already used.")


def _rate_limited(exc: RateLimited) -> ApiError:
    return ApiError(429, "rate_limited", "Too many requests. Try again later.", headers={"Retry-After": str(exc.retry_after_s)})


@router.post(
    "/auth/otp/request",
    status_code=202,
    response_model=OtpRequestAccepted,
    responses=responses(422, 429, 503),
    summary="Request a one-time sign-in code",
    description=(
        "Always answers 202 for eligible input so that registered/eligible numbers cannot be enumerated. "
        "Development/staging: only allow-listed test numbers receive a challenge (fixed test code, nothing is sent). "
        "Production: returns 503 until an SMS provider is configured (U-4)."
    ),
)
async def request_otp(body: OtpRequest, auth: Auth, ip: ClientIp) -> OtpRequestAccepted:
    try:
        await auth.request_otp(body.phone, ip)
    except RateLimited as exc:
        raise _rate_limited(exc) from None
    except OtpDeliveryUnavailable:
        raise ApiError(503, "otp_delivery_unavailable", "Sign-in codes cannot be delivered at the moment.") from None
    return OtpRequestAccepted()


@router.post("/auth/otp/verify", response_model=TokenPair, responses=responses(401, 422, 429), summary="Exchange phone + code for tokens")
async def verify_otp(body: OtpVerify, auth: Auth, ip: ClientIp, response: Response) -> TokenPair:
    try:
        pair = await auth.verify_otp(body.phone, body.code, ip)
    except RateLimited as exc:
        raise _rate_limited(exc) from None
    except AuthFailed:
        raise _invalid() from None
    response.headers["Cache-Control"] = "no-store"
    return pair


@router.post("/auth/refresh", response_model=TokenPair, responses=responses(401, 422), summary="Rotate the refresh token and get a new access token")
async def refresh(body: RefreshRequest, auth: Auth, ip: ClientIp, response: Response) -> TokenPair:
    try:
        pair = await auth.refresh(body.refresh_token, ip)
    except AuthFailed:
        raise ApiError(401, "invalid_refresh_token", "The refresh token is invalid, expired or already used.") from None
    response.headers["Cache-Control"] = "no-store"
    return pair


@router.post("/auth/logout", status_code=204, responses=responses(401), summary="Revoke the current session")
async def logout(principal: CurrentPrincipal, auth: Auth, ip: ClientIp) -> Response:
    await auth.logout(principal, ip)
    return Response(status_code=204)


@router.get("/me", response_model=UserProfile, responses=responses(401), tags=["profile"], summary="Current user profile")
async def me(principal: CurrentPrincipal, auth: Auth) -> UserProfile:
    return await auth.get_profile(principal.user_id)


@router.patch("/me", response_model=UserProfile, responses=responses(401, 422), tags=["profile"], summary="Update display name")
async def update_me(body: UpdateProfile, principal: CurrentPrincipal, auth: Auth) -> UserProfile:
    return await auth.update_profile(principal.user_id, body.display_name)
