"""Farm and device endpoints. There is NO device-control endpoint: devices are read-only here."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from gossy.api.deps import AdminPrincipal, ClientIp, CurrentPrincipal, service
from gossy.api.errors import responses
from gossy.devices.schemas import AdminDeviceCreate, ClaimRequest, Device, Farm, FarmCreate, ProvisionedDevice, RegistrationState
from gossy.devices.service import DeviceService

router = APIRouter(prefix="/api/v1")
Devices = Annotated[DeviceService, Depends(service("devices"))]


@router.post("/farms", status_code=201, response_model=Farm, responses=responses(401, 422), tags=["farms"], summary="Create a farm owned by the caller")
async def create_farm(body: FarmCreate, principal: CurrentPrincipal, svc: Devices) -> Farm:
    return await svc.create_farm(principal, body.name)


@router.get("/farms", response_model=list[Farm], responses=responses(401), tags=["farms"], summary="Farms owned by the caller")
async def list_farms(principal: CurrentPrincipal, svc: Devices) -> list[Farm]:
    return await svc.list_farms(principal)


@router.get("/farms/{farm_id}", response_model=Farm, responses=responses(401, 404), tags=["farms"], summary="One farm owned by the caller")
async def get_farm(farm_id: uuid.UUID, principal: CurrentPrincipal, svc: Devices) -> Farm:
    return await svc.get_farm(principal, farm_id)


@router.get("/devices", response_model=list[Device], responses=responses(401, 422), tags=["devices"], summary="Active devices on the caller's farms, with status")
async def list_devices(principal: CurrentPrincipal, svc: Devices, farm_id: Annotated[uuid.UUID | None, Query(alias="farmId")] = None) -> list[Device]:
    return await svc.list_devices(principal, farm_id)


@router.post("/devices/claim", response_model=Device, responses=responses(401, 404, 422, 429), tags=["devices"], summary="Attach a provisioned device to one of the caller's farms using its claim code")
async def claim_device(body: ClaimRequest, principal: CurrentPrincipal, svc: Devices, ip: ClientIp) -> Device:
    return await svc.claim(principal, body.device_id, body.claim_code, body.farm_id, ip)


@router.get("/devices/{device_id}", response_model=Device, responses=responses(401, 404), tags=["devices"], summary="Device identity, registration state, status and last-seen time")
async def get_device(device_id: str, principal: CurrentPrincipal, svc: Devices) -> Device:
    return await svc.get_device(principal, device_id)


# ------------------------------------------------------------------ admin (provisioning only)
@router.post("/admin/devices", status_code=201, response_model=ProvisionedDevice, responses=responses(401, 403, 409, 422), tags=["admin"], summary="Register a device and issue a one-time claim code")
async def admin_register(body: AdminDeviceCreate, admin: AdminPrincipal, svc: Devices) -> ProvisionedDevice:
    device, code, expires = await svc.register(admin, body.device_id, body.display_name)
    return ProvisionedDevice(device=device, claim_code=code, claim_code_expires_at=expires)


@router.get("/admin/devices", response_model=list[Device], responses=responses(401, 403, 422), tags=["admin"], summary="All registered devices")
async def admin_list(admin: AdminPrincipal, svc: Devices, state: Annotated[RegistrationState | None, Query()] = None) -> list[Device]:
    return await svc.admin_list(state)


@router.post("/admin/devices/{device_id}/claim-code", response_model=ProvisionedDevice, responses=responses(401, 403, 404), tags=["admin"], summary="Detach the device and issue a new claim code (transfer / lost label)")
async def admin_reissue(device_id: str, admin: AdminPrincipal, svc: Devices) -> ProvisionedDevice:
    device, code, expires = await svc.reissue_claim_code(admin, device_id)
    return ProvisionedDevice(device=device, claim_code=code, claim_code_expires_at=expires)


@router.post("/admin/devices/{device_id}/decommission", response_model=Device, responses=responses(401, 403, 404), tags=["admin"], summary="Retire a device from the registry")
async def admin_decommission(device_id: str, admin: AdminPrincipal, svc: Devices) -> Device:
    return await svc.decommission(admin, device_id)
