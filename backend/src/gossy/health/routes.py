"""/healthz = process is alive (no dependencies). /readyz = dependencies are usable (503 otherwise).

Checks and optional extra info are read from ``app.state.readiness_checks`` and
``app.state.readiness_info`` so each service (API, ingest) supplies its own.
"""

from __future__ import annotations

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from gossy.health.checks import run_checks

router = APIRouter(tags=["health"])


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(request: Request) -> JSONResponse:
    results = await run_checks(list(getattr(request.app.state, "readiness_checks", [])))
    ready = all(r.ok for r in results)
    body: dict[str, object] = {
        "status": "ready" if ready else "not_ready",
        "checks": {r.name: {"ok": r.ok, "detail": r.detail} for r in results},
    }
    info = getattr(request.app.state, "readiness_info", None)
    if info is not None:
        body["info"] = info()
    return JSONResponse(body, status_code=200 if ready else 503)
