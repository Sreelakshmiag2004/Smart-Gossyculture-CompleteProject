"""Consistent error responses.

Every error body is ``{"error": {"code", "message", "requestId", "details"?}}``. Messages are
safe for clients: no stack traces, SQL, token contents or echoed input values.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from starlette.exceptions import HTTPException as StarletteHTTPException

from gossy.logging_setup import request_id_var

log = logging.getLogger("gossy.api.errors")


class ErrorDetail(BaseModel):
    code: str
    message: str
    requestId: str | None = None
    details: list[dict] | None = None


class ErrorResponse(BaseModel):
    error: ErrorDetail


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, *, headers: dict[str, str] | None = None, details: list[dict] | None = None):
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers
        self.details = details


def unauthenticated(message: str = "Authentication required.") -> ApiError:
    return ApiError(401, "unauthenticated", message, headers={"WWW-Authenticate": "Bearer"})


def forbidden(message: str = "You do not have permission to perform this action.") -> ApiError:
    return ApiError(403, "forbidden", message)


def not_found(what: str = "Resource") -> ApiError:
    # Also used for resources that exist but belong to someone else, so existence is not revealed.
    return ApiError(404, "not_found", f"{what} not found.")


def error_response(status: int, code: str, message: str, *, headers=None, details=None) -> JSONResponse:
    body = {"error": {"code": code, "message": message, "requestId": request_id_var.get()}}
    if details:
        body["error"]["details"] = details
    return JSONResponse(body, status_code=status, headers=headers)


_STATUS_CODES = {400: "bad_request", 401: "unauthenticated", 403: "forbidden", 404: "not_found", 405: "method_not_allowed", 413: "payload_too_large", 429: "rate_limited"}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError):
        return error_response(exc.status, exc.code, exc.message, headers=exc.headers, details=exc.details)

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError):
        details = [{"loc": [str(p) for p in e.get("loc", ())], "type": e.get("type"), "message": e.get("msg")} for e in exc.errors()[:20]]
        return error_response(422, "validation_failed", "The request is invalid.", details=details)

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException):
        code = _STATUS_CODES.get(exc.status_code, "http_error")
        message = exc.detail if isinstance(exc.detail, str) and exc.status_code < 500 else "Request failed."
        return error_response(exc.status_code, code, message, headers=getattr(exc, "headers", None))

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception):
        request.app.state.unhandled_errors = getattr(request.app.state, "unhandled_errors", 0) + 1
        log.exception("unhandled_error", extra={"path": request.url.path, "error_type": type(exc).__name__})
        return error_response(500, "internal_error", "An unexpected error occurred.")


def responses(*statuses: int) -> dict[int, dict]:
    """OpenAPI documentation of error responses for a route."""
    text = {
        401: "Missing, invalid or expired access token (WWW-Authenticate: Bearer).",
        403: "Authenticated but not permitted (e.g. admin-only endpoint).",
        404: "Not found, or not accessible to the caller (existence is not revealed).",
        409: "Conflicts with the current state of the resource.",
        413: "Request body too large.",
        422: "Request validation failed.",
        429: "Rate limit exceeded (see Retry-After).",
        503: "Required service unavailable.",
    }
    return {s: {"model": ErrorResponse, "description": text[s]} for s in statuses}
