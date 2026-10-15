from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import Field

from gossy.auth.schemas import ApiModel
from gossy.contracts.topics import DEVICE_ID_PATTERN

DeviceIdField = Annotated[str, Field(pattern=DEVICE_ID_PATTERN, description="Device identity (= MQTT username / topic deviceId)", examples=["bb-000123"])]
RegistrationState = Literal["provisioned", "active", "decommissioned"]


class FarmCreate(ApiModel):
    name: Annotated[str, Field(min_length=1, max_length=80)]


class Farm(ApiModel):
    id: uuid.UUID
    name: str
    created_at: datetime


class DeviceStatus(ApiModel):
    state: Literal["online", "offline"] | None = Field(description="Last reported connection state (null if never reported)")
    state_at: datetime | None = Field(description="When the backend received that state")
    last_seen_at: datetime | None = Field(description="Receipt time of the last message from the device")


class Device(ApiModel):
    device_id: str
    display_name: str | None
    farm_id: uuid.UUID | None
    registration_state: RegistrationState
    registered_at: datetime
    claimed_at: datetime | None
    status: DeviceStatus
    telemetry_interval_s: int = Field(description="How often a device reports telemetry, in seconds (the contract's reporting interval)")
    telemetry_stale_after_s: int = Field(
        description="A telemetry reading is no longer current when the backend has received none for this many seconds. "
        "Measure against TelemetryPoint.receivedAt and the server's clock, not the device timestamp."
    )


class ClaimRequest(ApiModel):
    device_id: DeviceIdField
    claim_code: Annotated[str, Field(min_length=6, max_length=32, description="Code printed on the device label, e.g. ABCD-EFGH-JKLM")]
    farm_id: uuid.UUID


class AdminDeviceCreate(ApiModel):
    device_id: DeviceIdField
    display_name: Annotated[str, Field(min_length=1, max_length=80)] | None = None


class ProvisionedDevice(ApiModel):
    device: Device
    claim_code: str = Field(description="Shown ONCE. Only a hash is stored.")
    claim_code_expires_at: datetime
