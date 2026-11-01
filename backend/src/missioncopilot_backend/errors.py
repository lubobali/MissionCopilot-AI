"""Every error as RFC 9457 Problem Details (application/problem+json), as the API contract says. A
crash answers with a generic 500: no stack trace and no exception text, which can hold secrets. Bad
input is named by location and error type, never echoed back."""

from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

PROBLEM = "application/problem+json"


def problem(status: int, detail: str | None = None, **extra: object) -> JSONResponse:
    body: dict[str, object] = {
        "type": "about:blank",
        "title": HTTPStatus(status).phrase,
        "status": status,
    }
    if detail:
        body["detail"] = detail
    body.update(extra)
    return JSONResponse(body, status_code=status, media_type=PROBLEM)


def _http_error(_: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, HTTPException):
        return problem(500)
    response = problem(exc.status_code)
    response.headers.update(exc.headers or {})
    return response


def _invalid_input(_: Request, exc: Exception) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        return problem(500)
    errors = [{"loc": list(error["loc"]), "type": error["type"]} for error in exc.errors()]
    return problem(422, "The request does not match the contract.", errors=errors)


def _crash(_: Request, __: Exception) -> JSONResponse:
    return problem(500)


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(HTTPException, _http_error)
    app.add_exception_handler(RequestValidationError, _invalid_input)
    app.add_exception_handler(Exception, _crash)
