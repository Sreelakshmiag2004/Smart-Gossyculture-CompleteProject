from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel

from gossy.config import E164_PATTERN

Phone = Annotated[str, Field(pattern=E164_PATTERN, description="E.164 phone number, e.g. +99900000001", examples=["+99900000001"])]
Role = Literal["farmer", "admin"]


class ApiModel(BaseModel):
    """Base for request/response bodies: camelCase JSON, unknown request fields rejected."""

    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="forbid")


class OtpRequest(ApiModel):
    phone: Phone


class OtpRequestAccepted(ApiModel):
    status: Literal["accepted"] = "accepted"
    message: str = "If this number can receive codes, a code has been issued."


class OtpVerify(ApiModel):
    phone: Phone
    code: Annotated[str, Field(pattern=r"^[0-9]{6}$", description="6-digit one-time code")]


class RefreshRequest(ApiModel):
    refresh_token: Annotated[str, Field(min_length=20, max_length=200)]


class UserProfile(ApiModel):
    id: uuid.UUID
    phone: str
    display_name: str | None
    role: Role
    created_at: datetime
    last_login_at: datetime | None


class UpdateProfile(ApiModel):
    display_name: Annotated[str, Field(min_length=1, max_length=80)]


class TokenPair(ApiModel):
    token_type: Literal["Bearer"] = "Bearer"
    access_token: str
    access_token_expires_at: datetime
    refresh_token: str
    refresh_token_expires_at: datetime
    user: UserProfile
